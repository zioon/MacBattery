import XCTest
@testable import MacBatteryCore

/// 电池能量流统计（放电 / 充电容量、接电能量）测试。
///
/// 这块逻辑直接决定面板上的「已用 / 充入 / 能耗 / 偏差」数字，而本机没有 Swift 工具链，
/// 这些用例是唯一能在合并前验证算法的通道 —— 因此每个状态判定、跳过与累加分支都要覆盖。
final class PowerFlowEstimateTests: XCTestCase {

    /// 最小采样点：只保留积分真正关心的字段。
    private struct Point: PowerFlowSample {
        var flowTimestamp: TimeInterval
        var flowVoltage: Double = 11.4
        var flowCurrent: Double = 1.0
        var flowSystemWatts: Double = 10.0
        var flowExternalPower: Bool? = false
        var flowIsCharging: Bool = false
        var flowCapacityMilliAmpHours: Int?
    }

    private func sample(_ t: TimeInterval,
                        current: Double = 1.0,
                        voltage: Double = 11.4,
                        watts: Double = 10.0,
                        externalPower: Bool? = false,
                        charging: Bool = false,
                        capacity: Int? = nil) -> Point {
        Point(flowTimestamp: t,
              flowVoltage: voltage,
              flowCurrent: current,
              flowSystemWatts: watts,
              flowExternalPower: externalPower,
              flowIsCharging: charging,
              flowCapacityMilliAmpHours: capacity)
    }

    private func discharge(_ t: TimeInterval, current: Double = 1.0,
                           capacity: Int? = nil) -> Point {
        sample(t, current: current, externalPower: false, capacity: capacity)
    }

    private func charging(_ t: TimeInterval, current: Double = 2.0,
                          capacity: Int? = nil) -> Point {
        sample(t, current: current, externalPower: true, charging: true, capacity: capacity)
    }

    private func plugged(_ t: TimeInterval, watts: Double = 10.0) -> Point {
        sample(t, watts: watts, externalPower: true, charging: false)
    }

    // MARK: - 状态判定

    func testStatePriority() {
        XCTAssertEqual(PowerFlowIntegrator.state(of: sample(0, externalPower: false)), .discharging)
        XCTAssertEqual(PowerFlowIntegrator.state(of: sample(0, externalPower: true)), .pluggedIdle)
        XCTAssertEqual(PowerFlowIntegrator.state(of: sample(0, externalPower: true, charging: true)), .charging)
        // 旧数据没有外电列，但在充电 → 仍可归入充电。
        XCTAssertEqual(PowerFlowIntegrator.state(of: sample(0, externalPower: nil, charging: true)), .charging)
        XCTAssertEqual(PowerFlowIntegrator.state(of: sample(0, externalPower: nil)), .unknown)
    }

    // MARK: - 放电

    /// 均匀 60s、1 A 放电 10 段：mAh 必须等于 I × t / 3.6。
    func testIntegratesUniformDischarge() {
        let points = (0...10).map { discharge(TimeInterval($0) * 60, capacity: 3000) }

        let estimate = PowerFlowIntegrator.estimate(points)

        XCTAssertEqual(estimate.discharge.usedMilliAmpHours, 600.0 / 3.6, accuracy: 1e-6)
        XCTAssertEqual(estimate.discharge.dischargeSeconds, 600, accuracy: 1e-9)
        XCTAssertEqual(estimate.discharge.gapSeconds, 0, accuracy: 1e-9)
        XCTAssertTrue(estimate.discharge.isPureDischarge)
        XCTAssertTrue(estimate.discharge.canEstimateFullCharge)
        XCTAssertEqual(estimate.discharge.estimatedFullChargeMilliAmpHours ?? .nan,
                       3000 + 600.0 / 3.6, accuracy: 1e-6)
        // 充电 / 接电都没发生，必须为空占位而不是 0 参与展示。
        XCTAssertFalse(estimate.charge.hasIntegration)
        XCTAssertFalse(estimate.plugged.hasIntegration)
    }

    /// 采样间隔不均匀时按梯形积分，而不是当成等间隔。
    func testTrapezoidHandlesUnevenIntervals() {
        let points = [
            discharge(0, current: 1.0),
            discharge(36, current: 2.0),
            discharge(96, current: 0.5)
        ]

        let estimate = PowerFlowIntegrator.estimate(points)

        let expected = 1.5 * 36 / 3.6 + 1.25 * 60 / 3.6
        XCTAssertEqual(estimate.discharge.usedMilliAmpHours, expected, accuracy: 1e-6)
        XCTAssertEqual(estimate.discharge.dischargeSeconds, 96, accuracy: 1e-9)
        XCTAssertEqual(estimate.discharge.totals.intervals, 2)
    }

    /// 系统容量下降与积分口径的偏差。
    func testDischargeCapacityDropAndDeviation() {
        let points = (0...10).map {
            discharge(TimeInterval($0) * 60, capacity: $0 == 0 ? 3000 : 2500)
        }

        let estimate = PowerFlowIntegrator.estimate(points)

        XCTAssertEqual(estimate.discharge.firstCapacity, 3000)
        XCTAssertEqual(estimate.discharge.lastCapacity, 2500)
        XCTAssertEqual(estimate.discharge.systemDropMilliAmpHours, 500)

        let used = 600.0 / 3.6
        XCTAssertEqual(estimate.discharge.deviationMilliAmpHours ?? .nan,
                       used - 500, accuracy: 1e-6)
        XCTAssertEqual(estimate.discharge.deviationRatio ?? .nan,
                       (used - 500) / 500, accuracy: 1e-6)
    }

    // MARK: - 充电

    /// 充电段按同一 mAh 公式积分，并与系统容量上升值对照。
    func testIntegratesChargingAndComparesWithRise() {
        let points = (0...10).map {
            charging(TimeInterval($0) * 60, current: 2.0,
                     capacity: $0 == 0 ? 2000 : 2200)
        }

        let estimate = PowerFlowIntegrator.estimate(points)

        XCTAssertEqual(estimate.charge.chargedMilliAmpHours, 1200.0 / 3.6, accuracy: 1e-6)
        XCTAssertEqual(estimate.charge.chargeSeconds, 600, accuracy: 1e-9)
        XCTAssertTrue(estimate.charge.isPureCharge)
        XCTAssertEqual(estimate.charge.systemRiseMilliAmpHours, 200)
        XCTAssertEqual(estimate.charge.deviationMilliAmpHours ?? .nan,
                       1200.0 / 3.6 - 200, accuracy: 1e-6)

        // 纯充电窗口不应被误判成放电。
        XCTAssertFalse(estimate.discharge.hasIntegration)
        XCTAssertFalse(estimate.discharge.isPureDischarge)
    }

    /// 容量下降的充电窗口（读数跳变 / 拔电混合）不产生上升量，也就没有偏差对比。
    func testChargingWithFallingCapacityHasNoRise() {
        let points = [charging(0, capacity: 2200), charging(60, capacity: 2000)]

        let estimate = PowerFlowIntegrator.estimate(points)

        XCTAssertNil(estimate.charge.systemRiseMilliAmpHours)
        XCTAssertNil(estimate.charge.deviationMilliAmpHours)
    }

    // MARK: - 接电能量

    /// 接电段按整机功率积分：10 W × 1 h = 10 Wh。
    func testIntegratesPluggedEnergy() {
        let points = (0...60).map { plugged(TimeInterval($0) * 60, watts: 10) }

        let estimate = PowerFlowIntegrator.estimate(points)

        XCTAssertEqual(estimate.plugged.energyWattHours, 10, accuracy: 1e-9)
        XCTAssertEqual(estimate.plugged.pluggedSeconds, 3600, accuracy: 1e-9)
        XCTAssertTrue(estimate.plugged.isPurePlugged)
        XCTAssertEqual(estimate.plugged.averageWatts ?? .nan, 10, accuracy: 1e-9)
        XCTAssertFalse(estimate.discharge.hasIntegration)
        XCTAssertFalse(estimate.charge.hasIntegration)
    }

    /// 充电也算接电：整机功率积分覆盖充电时段，与容量积分互不干扰。
    func testChargingCountsAsPluggedEnergy() {
        let points = (0...60).map {
            charging(TimeInterval($0) * 60, current: 2,
                     capacity: $0 == 0 ? 2000 : 2200)
        }

        let estimate = PowerFlowIntegrator.estimate(points)

        XCTAssertEqual(estimate.charge.chargedMilliAmpHours, 2 * 3600 / 3.6, accuracy: 1e-6)
        XCTAssertEqual(estimate.plugged.energyWattHours, 10, accuracy: 1e-9)
        XCTAssertEqual(estimate.plugged.pluggedSeconds, 3600, accuracy: 1e-9)
    }

    // MARK: - 分段与边界

    /// 三类状态各自独立累计，互不污染。
    func testSegmentsAreIndependent() {
        let points = [
            discharge(0, capacity: 3000), discharge(60, capacity: 2990),
            charging(120, capacity: 2990), charging(180, capacity: 3000),
            plugged(240, watts: 5), plugged(300, watts: 5)
        ]

        let estimate = PowerFlowIntegrator.estimate(points)

        XCTAssertEqual(estimate.discharge.usedMilliAmpHours, 60.0 / 3.6, accuracy: 1e-6)
        XCTAssertEqual(estimate.charge.chargedMilliAmpHours, 120.0 / 3.6, accuracy: 1e-6)
        XCTAssertEqual(estimate.plugged.energyWattHours, 5 * 60 / 3600, accuracy: 1e-9)
        // 混合窗口：三类都不是「纯」的，因此不给满充估算与偏差对比。
        XCTAssertFalse(estimate.discharge.isPureDischarge)
        XCTAssertFalse(estimate.charge.isPureCharge)
        XCTAssertFalse(estimate.plugged.isPurePlugged)
        XCTAssertNil(estimate.discharge.estimatedFullChargeMilliAmpHours)
        XCTAssertNil(estimate.discharge.deviationMilliAmpHours)
        XCTAssertNil(estimate.charge.deviationMilliAmpHours)
    }

    /// 旧数据没有外电列（nil）：状态未知，绝不归入任何积分。
    func testUnknownPowerStateIsNotIntegrated() {
        let points = [
            discharge(0), sample(60, externalPower: nil), discharge(120)
        ]

        let estimate = PowerFlowIntegrator.estimate(points)

        XCTAssertTrue(estimate.hadUnknownPowerState)
        XCTAssertFalse(estimate.discharge.hasIntegration)
        XCTAssertFalse(estimate.charge.hasIntegration)
        XCTAssertFalse(estimate.plugged.hasIntegration)
        XCTAssertEqual(estimate.discharge.usedMilliAmpHours, 0, accuracy: 1e-9)
    }

    /// 超过 600s 的数据缺口整段跳过，并如实记入 gap，不硬凑端点均值。
    func testLongGapIsSkipped() {
        let points = [discharge(0, capacity: 3000), discharge(1200, capacity: 2900)]

        let estimate = PowerFlowIntegrator.estimate(points)

        XCTAssertEqual(estimate.discharge.usedMilliAmpHours, 0, accuracy: 1e-9)
        XCTAssertEqual(estimate.discharge.gapSeconds, 1200, accuracy: 1e-9)
        // 状态本身是纯放电，但缺口让满充估算不可信。
        XCTAssertTrue(estimate.discharge.isPureDischarge)
        XCTAssertFalse(estimate.discharge.canEstimateFullCharge)
        XCTAssertNil(estimate.discharge.estimatedFullChargeMilliAmpHours)
    }

    /// 电压 / 电流越界（含 0 与异常尖峰）的段不积分，计入缺口。
    func testImplausibleReadingsAreSkipped() {
        let points = [
            sample(0, current: 1.0, voltage: 11.4, externalPower: false),
            sample(60, current: 1.0, voltage: 0, externalPower: false),
            sample(120, current: 100, voltage: 11.4, externalPower: false),
            sample(180, current: 1.0, voltage: 11.4, externalPower: false)
        ]

        let estimate = PowerFlowIntegrator.estimate(points)

        XCTAssertEqual(estimate.discharge.totals.intervals, 0)
        XCTAssertEqual(estimate.discharge.usedMilliAmpHours, 0, accuracy: 1e-9)
        XCTAssertEqual(estimate.discharge.gapSeconds, 180, accuracy: 1e-9)
    }

    /// 接电功率越界同样跳过并计入缺口。
    func testImplausibleWattsAreSkipped() {
        let points = [plugged(0, watts: 10), plugged(60, watts: -5), plugged(120, watts: 10)]

        let estimate = PowerFlowIntegrator.estimate(points)

        XCTAssertEqual(estimate.plugged.totals.intervals, 0)
        XCTAssertEqual(estimate.plugged.energyWattHours, 0, accuracy: 1e-9)
        XCTAssertEqual(estimate.plugged.gapSeconds, 120, accuracy: 1e-9)
    }

    /// 空序列与单点都退化为「没有可估算的段」。
    func testEmptyAndSingleSample() {
        let empty = PowerFlowIntegrator.estimate([Point]())
        XCTAssertEqual(empty, PowerFlowEstimate.empty)
        XCTAssertFalse(empty.discharge.hasIntegration)
        XCTAssertFalse(empty.charge.hasIntegration)
        XCTAssertFalse(empty.plugged.hasIntegration)

        let single = PowerFlowIntegrator.estimate([discharge(0, capacity: 3000)])
        XCTAssertEqual(single.sampleCount, 1)
        XCTAssertFalse(single.discharge.hasIntegration)
        XCTAssertFalse(single.discharge.isPureDischarge)
        XCTAssertFalse(single.discharge.canEstimateFullCharge)
    }
}
