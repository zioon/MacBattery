import Foundation
import Combine

/// 数据中枢：每秒读取一次电量、充电功率、整机功率。
@MainActor
final class PowerMonitor: ObservableObject {

    /// 电量百分比（0...100）
    @Published var batteryPercent: Int = 0
    /// 整机功率（瓦特）
    @Published var systemWatts: Double = 0
    /// 当前充电功率（瓦特）
    @Published var chargingWatts: Double = 0

    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        batteryPercent = BatteryReader.level()
        chargingWatts = BatteryReader.chargingWatts()
        systemWatts = SMCReader.systemWatts()
    }
}