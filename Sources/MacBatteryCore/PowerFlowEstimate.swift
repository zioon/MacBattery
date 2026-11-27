import Foundation

/// 参与「容量 / 能量」积分的单个采样点。
///
/// 刻意用协议而不是直接依赖 `PowerSample`：`PowerSample` 在 App target（依赖 AppKit），
/// 而积分逻辑必须留在纯逻辑层才能被 `swift test` 覆盖 —— 本机没有 Swift 工具链，
/// CI 的单测是这部分算法唯一的验证通道。
///
/// ⚠️ **电流取绝对值**：注册表 `Amperage` 的符号约定不统一（部分机型放电也为负），
/// 上游 `BatteryStatus.current` 已统一取绝对值、方向由 `isCharging` / `externalPower`
/// 判断，因此这里直接使用正值。充放电都按同一口径积分。
public protocol PowerFlowSample {
    /// 采样时刻（Unix 秒，允许小数）。
    var flowTimestamp: TimeInterval { get }
    /// 电池电压（伏特）。
    var flowVoltage: Double { get }
    /// 电池电流绝对值（安培）。
    var flowCurrent: Double { get }
    /// 整机功率（瓦特，含估算回退值）。
    var flowSystemWatts: Double { get }
    /// 是否接通外部电源：false = 电池供电，true = 接电，nil = 未知（旧落盘数据）。
    var flowExternalPower: Bool? { get }
    /// 是否正在充电。
    var flowIsCharging: Bool { get }
    /// 当前剩余容量（mAh，`AppleRawCurrentCapacity`）。nil = 未知。
    var flowCapacityMilliAmpHours: Int? { get }
}

/// 一段采样所属的能量流状态。
///
/// 三类互斥，判定有严格的优先级：**充电优先**（`isCharging` 即使在外电列缺失时也可信，
/// 因此旧数据只要在充电仍能归入充电段），其次才是外电列。
public enum PowerFlowState: Hashable {
    /// 电池供电（未接外电且不在充电）。
    case discharging
    /// 正在充电（= 正在从外部电源充入电池）。
    case charging
    /// 接电但不在充电（已充满 / 限充保持）。
    case pluggedIdle
    /// 旧数据缺少外电状态，无法归类。
    case unknown
}

/// 一段同类状态的积分总量。
public struct SegmentTotals: Equatable {
    /// 积分结果：容量段为 mAh，能量段为 Wh。
    public var amount: Double
    /// 真正计入积分的时长（秒）。
    public var seconds: TimeInterval
    /// 因数据缺口 / 读数无效被跳过的时长（秒）。
    ///
    /// > 0 说明窗口内有采样中断或不可用读数，此时积分值偏小 ——
    /// 展示层据此提示，而不是假装完整。
    public var gapSeconds: TimeInterval
    /// 计入积分的时间段数。0 表示窗口内没有可与该状态匹配的段。
    public var intervals: Int

    public var hasIntegration: Bool { intervals > 0 }

    public static let empty = SegmentTotals(amount: 0, seconds: 0, gapSeconds: 0, intervals: 0)
}

/// 电池供电段：按电流积分得到的已用容量（mAh）。
public struct DischargeEstimate: Equatable {
    public var totals: SegmentTotals
    public var firstCapacity: Int?
    public var lastCapacity: Int?
    /// 整个窗口是否都是明确的电池供电状态（用于「剩余 + 已用 = 满充」这类推断）。
    public var isPureDischarge: Bool

    public var usedMilliAmpHours: Double { totals.amount }
    public var dischargeSeconds: TimeInterval { totals.seconds }
    public var gapSeconds: TimeInterval { totals.gapSeconds }
    public var hasIntegration: Bool { totals.hasIntegration }

    /// 系统读数口径的容量下降（mAh）：窗口首末剩余容量之差。
    ///
    /// 只在**确实下降**时给出 —— 首末持平或上升（读数跳变）不构成可对比的量。
    public var systemDropMilliAmpHours: Int? {
        guard let first = firstCapacity, let last = lastCapacity else { return nil }
        let drop = first - last
        return drop > 0 ? drop : nil
    }

    /// 是否可以给出「估算满充容量」。
    ///
    /// 三个前提缺一不可：窗口纯放电（否则剩余 + 已用没有意义）、
    /// 没有任何数据缺口（缺口内的放电没被计入，会把满充估小）、首末容量都可读。
    public var canEstimateFullCharge: Bool {
        isPureDischarge && gapSeconds <= 0 && firstCapacity != nil && lastCapacity != nil
    }

    /// 估算满充容量（mAh）：窗口末剩余 + 本窗积分已用。
    ///
    /// 仅在 `canEstimateFullCharge` 为真时有意义。
    public var estimatedFullChargeMilliAmpHours: Double? {
        guard canEstimateFullCharge, let last = lastCapacity else { return nil }
        return Double(last) + usedMilliAmpHours
    }

    /// 积分口径与系统读数口径之差（mAh）：已用 − 系统下降。正 = 积分偏大。
    public var deviationMilliAmpHours: Double? {
        guard canEstimateFullCharge, let drop = systemDropMilliAmpHours else { return nil }
        return usedMilliAmpHours - Double(drop)
    }

    /// 相对系统下降的偏差（比例，0.05 = +5%）。
    public var deviationRatio: Double? {
        guard let deviation = deviationMilliAmpHours,
              let drop = systemDropMilliAmpHours, drop > 0 else { return nil }
        return deviation / Double(drop)
    }
}

/// 充电段：按电流积分得到的充入容量（mAh）。
public struct ChargeEstimate: Equatable {
    public var totals: SegmentTotals
    public var firstCapacity: Int?
    public var lastCapacity: Int?
    /// 整个窗口是否都在充电。
    public var isPureCharge: Bool

    public var chargedMilliAmpHours: Double { totals.amount }
    public var chargeSeconds: TimeInterval { totals.seconds }
    public var gapSeconds: TimeInterval { totals.gapSeconds }
    public var hasIntegration: Bool { totals.hasIntegration }

    /// 系统读数口径的容量上升（mAh）：窗口首末剩余容量之差。
    public var systemRiseMilliAmpHours: Int? {
        guard let first = firstCapacity, let last = lastCapacity else { return nil }
        let rise = last - first
        return rise > 0 ? rise : nil
    }

    /// 是否可以与系统上升值做偏差对比：需要纯充电窗口且无数据缺口。
    public var canCompareWithSystem: Bool {
        isPureCharge && gapSeconds <= 0 && firstCapacity != nil && lastCapacity != nil
    }

    /// 充入容量 − 系统上升（mAh）。正 = 积分偏大。
    public var deviationMilliAmpHours: Double? {
        guard canCompareWithSystem, let rise = systemRiseMilliAmpHours else { return nil }
        return chargedMilliAmpHours - Double(rise)
    }

    /// 相对系统上升的偏差（比例）。
    public var deviationRatio: Double? {
        guard let deviation = deviationMilliAmpHours,
              let rise = systemRiseMilliAmpHours, rise > 0 else { return nil }
        return deviation / Double(rise)
    }
}

/// 接电段：按整机功率积分得到的消耗能量（Wh）。
///
/// 「接电」包含正在充电的时段 —— 整机功率是外部电源的总输出口径，
/// 充电时它同时覆盖系统负载与充入电池的部分。
public struct PluggedEnergyEstimate: Equatable {
    public var totals: SegmentTotals
    /// 整个窗口是否都在接电（含充电）。
    public var isPurePlugged: Bool

    public var energyWattHours: Double { totals.amount }
    public var pluggedSeconds: TimeInterval { totals.seconds }
    public var gapSeconds: TimeInterval { totals.gapSeconds }
    public var hasIntegration: Bool { totals.hasIntegration }

    /// 该时段的平均整机功率（W）。无有效积分时为 nil。
    public var averageWatts: Double? {
        guard pluggedSeconds > 0 else { return nil }
        return energyWattHours / (pluggedSeconds / 3600)
    }
}

/// 一段可见时间窗内三类能量流统计的汇总。
public struct PowerFlowEstimate: Equatable {
    public var discharge: DischargeEstimate
    public var charge: ChargeEstimate
    public var plugged: PluggedEnergyEstimate
    /// 窗口内的采样点数。
    public var sampleCount: Int
    /// 窗口内是否存在供电状态未知的采样点（旧数据没有外电列）。
    public var hadUnknownPowerState: Bool

    public static let empty = PowerFlowEstimate(
        discharge: DischargeEstimate(totals: .empty, firstCapacity: nil,
                                     lastCapacity: nil, isPureDischarge: false),
        charge: ChargeEstimate(totals: .empty, firstCapacity: nil,
                               lastCapacity: nil, isPureCharge: false),
        plugged: PluggedEnergyEstimate(totals: .empty, isPurePlugged: false),
        sampleCount: 0,
        hadUnknownPowerState: false)
}

/// 电池能量流统计（库仑计数 + 功率积分）。
///
/// 三类统计一次遍历完成，互斥分段：
/// - **放电**：容量，`mAh = Σ (I₁+I₂)/2 × dt / 3.6`（I 为安培、dt 为秒，1 mAh = 3.6 C）；
/// - **充电**：容量，同一公式（充入电池的电流）；
/// - **接电**：能量，`Wh = Σ (P₁+P₂)/2 × dt / 3600`（P 为整机瓦特）。
///
/// 容量是**电流**对时间的积分，电压只参与有效性校验、不进公式：
/// 用功率再除以电压的间接口径会把电压自身的缓变误差放大一次。
public enum PowerFlowIntegrator {

    /// 单段积分的最大时长（秒）。
    ///
    /// 稳态落盘是 1/60s 一条，但应用退出 / 休眠期间会有更长的空洞。
    /// 跨越大空洞的「端点均值」毫无意义（电流、功率可能完全变了），
    /// 因此超过该阈值就整段跳过并计入 `gapSeconds`，宁可少算也不编造。
    public static let maxIntervalSeconds: TimeInterval = 600

    /// 电池电压的合理区间（V）。超出即不是有效读数（如 0 或异常尖峰）。
    public static let plausibleVoltage: ClosedRange<Double> = 3.0...30.0

    /// 电流绝对值的合理区间（A）。笔记本电池充放电极少超过 20 A。
    public static let plausibleCurrent: ClosedRange<Double> = 0.0...20.0

    /// 整机功率的合理区间（W）。0 W 是合法的空闲下限，超过 1000 W 必是异常读数。
    public static let plausibleWatts: ClosedRange<Double> = 0.0...1000.0

    /// 判定某采样点所属的能量流状态（三类互斥，充电优先）。
    public static func state<S: PowerFlowSample>(of sample: S) -> PowerFlowState {
        if sample.flowIsCharging { return .charging }
        switch sample.flowExternalPower {
        case .some(false): return .discharging
        case .some(true): return .pluggedIdle
        case .none: return .unknown
        }
    }

    /// 对一段**按时间升序**的采样做三类积分与容量对照。
    ///
    /// 序列顺序不做校验：上游 `PowerLogger.samples` 始终按时间升序维护。
    public static func estimate<S: Sequence>(_ samples: S) -> PowerFlowEstimate
    where S.Element: PowerFlowSample {
        var dischargeTotals = SegmentTotals.empty
        var chargeTotals = SegmentTotals.empty
        var pluggedTotals = SegmentTotals.empty
        var dischargeFirst: Int?
        var dischargeLast: Int?
        var chargeFirst: Int?
        var chargeLast: Int?
        var seen: Set<PowerFlowState> = []
        var count = 0
        var previous: S.Element?
        var previousState: PowerFlowState?

        for sample in samples {
            count += 1
            let sampleState = state(of: sample)
            seen.insert(sampleState)

            if let capacity = sample.flowCapacityMilliAmpHours, capacity > 0 {
                switch sampleState {
                case .discharging:
                    if dischargeFirst == nil { dischargeFirst = capacity }
                    dischargeLast = capacity
                case .charging:
                    if chargeFirst == nil { chargeFirst = capacity }
                    chargeLast = capacity
                case .pluggedIdle, .unknown:
                    break
                }
            }

            if let prev = previous, let prevState = previousState {
                let dt = sample.flowTimestamp - prev.flowTimestamp
                // 只在「同状态」的相邻两点之间积分；状态切换本身就是合法边界，
                // 不把切换处的时间差算进任何一侧的缺口。
                if dt > 0 && prevState == sampleState {
                    switch sampleState {
                    case .discharging:
                        integrateCapacity(prev, sample, dt: dt, into: &dischargeTotals)
                    case .charging:
                        // 充电既是「充入容量」也是「接电能耗」：两条口径不同，
                        // 同一段同时累计，互不排斥。
                        integrateCapacity(prev, sample, dt: dt, into: &chargeTotals)
                        integrateEnergy(prev, sample, dt: dt, into: &pluggedTotals)
                    case .pluggedIdle:
                        integrateEnergy(prev, sample, dt: dt, into: &pluggedTotals)
                    case .unknown:
                        break
                    }
                }
            }

            previous = sample
            previousState = sampleState
        }

        let discharge = DischargeEstimate(
            totals: dischargeTotals,
            firstCapacity: dischargeFirst,
            lastCapacity: dischargeLast,
            isPureDischarge: isPure(count: count, seen: seen, state: .discharging))
        let charge = ChargeEstimate(
            totals: chargeTotals,
            firstCapacity: chargeFirst,
            lastCapacity: chargeLast,
            isPureCharge: isPure(count: count, seen: seen, state: .charging))
        let plugged = PluggedEnergyEstimate(
            totals: pluggedTotals,
            isPurePlugged: isPluggedOnly(count: count, seen: seen))

        return PowerFlowEstimate(discharge: discharge,
                                 charge: charge,
                                 plugged: plugged,
                                 sampleCount: count,
                                 hadUnknownPowerState: seen.contains(.unknown))
    }

    // MARK: - 积分

    /// 容量段：mAh = Σ 平均电流(A) × dt(s) / 3.6。
    private static func integrateCapacity<S: PowerFlowSample>(_ a: S, _ b: S,
                                                              dt: TimeInterval,
                                                              into totals: inout SegmentTotals) {
        guard dt <= maxIntervalSeconds,
              isPlausibleVoltage(a.flowVoltage),
              isPlausibleVoltage(b.flowVoltage),
              isPlausibleCurrent(a.flowCurrent),
              isPlausibleCurrent(b.flowCurrent) else {
            totals.gapSeconds += dt
            return
        }
        let averageAmps = (a.flowCurrent + b.flowCurrent) / 2
        let added = averageAmps * dt / 3.6
        guard added.isFinite else {
            totals.gapSeconds += dt
            return
        }
        totals.amount += added
        totals.seconds += dt
        totals.intervals += 1
    }

    /// 能量段：Wh = Σ 平均功率(W) × dt(s) / 3600。
    private static func integrateEnergy<S: PowerFlowSample>(_ a: S, _ b: S,
                                                            dt: TimeInterval,
                                                            into totals: inout SegmentTotals) {
        guard dt <= maxIntervalSeconds,
              isPlausibleWatts(a.flowSystemWatts),
              isPlausibleWatts(b.flowSystemWatts) else {
            totals.gapSeconds += dt
            return
        }
        let averageWatts = (a.flowSystemWatts + b.flowSystemWatts) / 2
        let added = averageWatts * dt / 3600
        guard added.isFinite else {
            totals.gapSeconds += dt
            return
        }
        totals.amount += added
        totals.seconds += dt
        totals.intervals += 1
    }

    // MARK: - 判定

    /// 窗口内是否「只有这一种状态」且至少两点（单点不存在积分段）。
    private static func isPure(count: Int, seen: Set<PowerFlowState>,
                               state: PowerFlowState) -> Bool {
        count >= 2 && seen.count == 1 && seen.contains(state)
    }

    /// 窗口内是否全在接电（充电也算接电），用于「接电能耗」的口径说明。
    private static func isPluggedOnly(count: Int, seen: Set<PowerFlowState>) -> Bool {
        guard count >= 2, !seen.isEmpty else { return false }
        return seen.allSatisfy { $0 == .charging || $0 == .pluggedIdle }
    }

    private static func isPlausibleVoltage(_ voltage: Double) -> Bool {
        voltage.isFinite && plausibleVoltage.contains(voltage)
    }

    private static func isPlausibleCurrent(_ current: Double) -> Bool {
        current.isFinite && plausibleCurrent.contains(current)
    }

    private static func isPlausibleWatts(_ watts: Double) -> Bool {
        watts.isFinite && plausibleWatts.contains(watts)
    }
}
