import Foundation
import Combine
import IOKit.ps

/// 后台采样器：一次完整采样电量 / 充电功率 / CPU / 内存 / 整机功率。
/// 所有读取均为 nonisolated，且只被后台串行采样队列调用，
/// 因此 BatteryReader / SMCReader 的静态缓存无需额外加锁。
enum Sampler {

    /// 单次采样的完整结果。
    struct Frame {
        var batteryPercent = 0
        var isCharging = false
        var chargingWatts = 0.0
        var cpuUsage = 0.0
        var memoryUsage = 0.0
        var systemWatts = 0.0
    }

    static func sample(tdp: Double) -> Frame {
        var f = Frame()
        f.batteryPercent = BatteryReader.level()

        let charging = BatteryReader.chargingStatus()
        f.isCharging = charging.isCharging
        f.chargingWatts = charging.watts

        // 先读一次 CPU 使用率，整机功率估算复用同一采样，避免重复计算。
        let u = SystemPower.cpuUsage()
        f.cpuUsage = u
        f.memoryUsage = SystemPower.memoryUsage()
        f.systemWatts = SystemPower.watts(tdp: tdp, usage: u)
        return f
    }
}

/// 数据中枢：每 0.5s 采样一次电量、充电功率、整机功率及其占用。
/// 采样在后台串行队列执行（SMC/IOKit 读取不阻塞 UI），完成后回主线程发布；
/// 并订阅 IOKit 电源事件，在插拔 / 充满 / 充电档位切换时立即补一次采样，提升时效。
@MainActor
final class PowerMonitor: ObservableObject {

    /// 电量百分比（0...100）
    @Published var batteryPercent: Int = 0
    /// 整机功率（瓦特）
    @Published var systemWatts: Double = 0
    /// 当前充电功率（瓦特）
    @Published var chargingWatts: Double = 0
    /// 是否正在充电
    @Published var isCharging: Bool = false
    /// CPU 使用率（0...1）
    @Published var cpuUsage: Double = 0
    /// 内存使用率（0...1）
    @Published var memoryUsage: Double = 0

    private let settings: SettingsStore
    private var timer: Timer?
    /// 后台串行采样队列：串行保证 Battery / SMC 静态缓存访问安全。
    private let sampleQueue = DispatchQueue(label: "MacBattery.sample", qos: .utility)
    /// IOKit 电源事件通知源（插拔 / 充满 / 功率切换时触发）。
    private var powerSourceSource: CFRunLoopSource?

    /// 采样间隔（秒）。
    private static let interval: TimeInterval = 0.5

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func start() {
        installPowerSourceNotification()
        scheduleSample()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleSample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let source = powerSourceSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
            powerSourceSource = nil
        }
    }

    /// 供顶层独立刷新（例如设置里调整 TDP 后立即更新）。
    func refreshOnce() {
        scheduleSample()
    }

    /// 主线程读取设置，派发后台采样，完成后回主线程发布。
    private func scheduleSample() {
        let tdp = settings.tdpWatts
        sampleQueue.async { [weak self] in
            let frame = Sampler.sample(tdp: tdp)
            Task { @MainActor [weak self] in self?.apply(frame) }
        }
    }

    private func apply(_ frame: Sampler.Frame) {
        batteryPercent = frame.batteryPercent
        isCharging = frame.isCharging
        chargingWatts = frame.chargingWatts
        cpuUsage = frame.cpuUsage
        memoryUsage = frame.memoryUsage
        systemWatts = frame.systemWatts
    }

    /// 订阅 IOKit 电源变化通知 —— 插拔 / 充满 / 充电档位切换时立即补一次采样。
    private func installPowerSourceNotification() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let source = IOPSNotificationCreateRunLoopSource({ info in
            guard let info else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(info).takeUnretainedValue()
            // 该通知源挂在主 RunLoop 上，回调天然在主线程执行。
            MainActor.assumeIsolated { monitor.powerSourceChanged() }
        }, context)?.takeRetainedValue() else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        powerSourceSource = source
    }

    /// 电源事件回调 —— 立即采样（不必等下一个 tick）。
    private func powerSourceChanged() {
        scheduleSample()
    }
}