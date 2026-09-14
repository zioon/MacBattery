import Foundation
import Combine

/// 数据中枢：每秒读取一次电量、充电功率、整机功率。
/// 整机功率结合用户设置的 TDP（最大功耗）做估算兜底。
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

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 供顶层独立刷新（例如设置里调整 TDP 后立即更新）。
    func refreshOnce() {
        refresh()
    }

    private func refresh() {
        batteryPercent = BatteryReader.level()

        let charging = BatteryReader.chargingStatus()
        isCharging = charging.isCharging
        chargingWatts = charging.watts

        // 先读一次 CPU 使用率，整机功率估算复用同一采样，避免重复计算。
        let u = SystemPower.cpuUsage()
        cpuUsage = u
        memoryUsage = SystemPower.memoryUsage()

        systemWatts = SystemPower.watts(tdp: settings.tdpWatts, usage: u)
    }
}