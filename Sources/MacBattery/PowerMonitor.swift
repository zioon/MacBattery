import Foundation
import Combine
import IOKit.ps

/// 后台采样器：一次完整采样电量 / 充电功率 / CPU / 内存 / 整机功率。
/// 所有读取均为 nonisolated；BatteryReader / SMCReader / SystemPower 的静态缓存
/// 由各自类型内部的 `NSRecursiveLock` 保护，可安全地在后台采样队列与主线程间共享。
enum Sampler {

    /// 单次采样的完整结果。
    struct Frame {
        var batteryPercent = 0
        var isCharging = false
        var chargingWatts = 0.0
        var chargingVoltage = 0.0
        var chargingCurrent = 0.0
        var cpuUsage = 0.0
        var memoryUsage = 0.0
        var systemWatts = 0.0
        /// 整机功率是否为估算值（true = 估算回退，UI 以 `~` 前缀区分）。仅用于实时 UI，不入 CSV。
        var systemWattsIsEstimate = false
    }

    static func sample(tdp: Double) -> Frame {
        var f = Frame()
        f.batteryPercent = BatteryReader.level()

        let charging = BatteryReader.chargingStatus()
        f.isCharging = charging.isCharging
        f.chargingWatts = charging.watts
        f.chargingVoltage = charging.voltage
        f.chargingCurrent = charging.current

        // 先读一次 CPU 使用率，整机功率估算复用同一采样，避免重复计算。
        let u = SystemPower.cpuUsage()
        f.cpuUsage = u
        f.memoryUsage = SystemPower.memoryUsage()
        let reading = SystemPower.watts(tdp: tdp, usage: u)
        f.systemWatts = reading.watts
        f.systemWattsIsEstimate = reading.isEstimate
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
    /// 当前的整机功率是否为估算值（true = 估算回退，UI 以 `~` 前缀标注）。仅用于实时 UI。
    @Published var systemWattsIsEstimate: Bool = false
    /// 当前充电功率（瓦特）
    @Published var chargingWatts: Double = 0
    /// 充电电压（伏特，仅供展示）
    @Published var chargingVoltage: Double = 0
    /// 充电电流（安培，仅供展示）
    @Published var chargingCurrent: Double = 0
    /// 是否正在充电
    @Published var isCharging: Bool = false
    /// CPU 使用率（0...1）
    @Published var cpuUsage: Double = 0
    /// 内存使用率（0...1）
    @Published var memoryUsage: Double = 0

    private let settings: SettingsStore
    /// 采样日志：每次采样完成后追加一条，供历史图表使用。
    private let logger: PowerLogger
    /// 后台串行采样队列：让采样脱离主 RunLoop 执行。
    /// 注意：主线程也存在硬件读取入口（首拍 / 电源事件补采样 / 健康日志），
    /// Battery / SMC / SystemPower 的静态缓存由各自内部的锁保护，而非依赖本队列串行。
    private let sampleQueue = DispatchQueue(label: "MacBattery.sample", qos: .utility)
    /// 后台精确采样定时器（0.5s），独立于主线程触发。
    private var sampleSource: DispatchSourceTimer?
    /// IOKit 电源事件通知源（插拔 / 充满 / 功率切换时触发）。
    private var powerSourceSource: CFRunLoopSource?
    /// TDP 的跨线程缓存：主线程写入，后台采样读取（值为 Double，竞争可忽略）。
    private let tdpBox = TDPBox()

    /// 采样间隔（秒）。
    private static let interval: TimeInterval = 0.5

    init(settings: SettingsStore, logger: PowerLogger) {
        self.settings = settings
        self.logger = logger
    }

    func start() {
        logger.start()
        installPowerSourceNotification()
        startSamplingTimer()
        scheduleSample()
    }

    func stop() {
        sampleSource?.cancel()
        sampleSource = nil
        logger.stop()
        if let source = powerSourceSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
            powerSourceSource = nil
        }
    }

    /// 供顶层独立刷新（例如设置里调整 TDP 后立即更新）。
    func refreshOnce() {
        scheduleSample()
    }

    /// 在后台串行队列上启动精确的采样心跳。
    /// 不依赖主 RunLoop 的 `Timer`，因此主线程即使被其他工作短暂占用，
    /// 或系统把低频主线程 timer 合并，都不会把采样间隔拉长。
    private func startSamplingTimer() {
        let src = DispatchSource.makeTimerSource(queue: sampleQueue)
        src.schedule(deadline: .now() + Self.interval,
                     repeating: Self.interval,
                     leeway: .milliseconds(20))
        src.setEventHandler { [weak self] in self?.performSampling() }
        src.resume()
        sampleSource = src
    }

    /// 主线程入口：刷新 TDP 缓存并立即采样一次（供电源事件即时触发 / 设置变更即时刷新）。
    private func scheduleSample() {
        tdpBox.value = settings.tdpWatts
        performSampling()
    }

    /// 后台采样（可在采样队列线程调用）：读缓存 TDP → 采样 → 回主线程发布与展示。
    private nonisolated func performSampling() {
        let frame = Sampler.sample(tdp: tdpBox.value)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 每次主线程收尾时刷新 TDP 缓存，让设置变更在下一拍生效。
            self.tdpBox.value = self.settings.tdpWatts
            self.apply(frame)
        }
    }

    private func apply(_ frame: Sampler.Frame) {
        batteryPercent = frame.batteryPercent
        isCharging = frame.isCharging
        chargingWatts = frame.chargingWatts
        chargingVoltage = frame.chargingVoltage
        chargingCurrent = frame.chargingCurrent
        cpuUsage = frame.cpuUsage
        memoryUsage = frame.memoryUsage
        systemWatts = frame.systemWatts
        systemWattsIsEstimate = frame.systemWattsIsEstimate
        // 记录一条样本到日志（供历史图表）。主线程追加，磁盘落盘由日志内部后台完成。
        logger.append(PowerSample(
            t: Date(),
            batteryPercent: frame.batteryPercent,
            isCharging: frame.isCharging,
            chargingWatts: frame.chargingWatts,
            chargingVoltage: frame.chargingVoltage,
            chargingCurrent: frame.chargingCurrent,
            cpuUsage: frame.cpuUsage,
            memoryUsage: frame.memoryUsage,
            systemWatts: frame.systemWatts
        ))
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

    /// 电源事件回调 —— 标记插拔（让充电状态短暂走 IOPS 即时路径，加快断电感知）并立即采样。
    private func powerSourceChanged() {
        BatteryReader.markBatteryEvent()
        scheduleSample()
    }
}

/// 跨线程 TDP 缓存：主线程（设置变更 / 每次采样收尾）写入，后台采样线程读取。
/// 仅存一个 Double，数据竞争可忽略，避免在 @MainActor 类内用 nonisolated(unsafe)。
private final class TDPBox {
    var value: Double

    init(_ value: Double = 45) {
        self.value = value
    }
}