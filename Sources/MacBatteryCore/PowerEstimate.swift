import Foundation

/// 整机功率的经验估算公式（原先散落在 SystemPower 里的魔数）。
///
/// 抽成纯函数：无任何系统依赖，可独立单测；后续如需按机型分档，只需在这里加档位。
public enum PowerEstimate {

    /// CPU 功耗曲线的下界系数：空闲时 CPU 功耗占 TDP 的比例。
    public static let cpuIdleFactor = 0.05
    /// CPU 功耗曲线的斜率：满载时 CPU 功耗占 TDP 的比例。
    public static let cpuLoadFactor = 0.95
    /// 平台基础功耗（CPU 之外的常驻部分，W）。
    public static let platformBase = 7.0
    /// 平台功耗随负载增长的部分（W）。
    public static let platformLoad = 3.0

    /// 估算整机功率 = CPU 功耗曲线 + 平台基础功耗。
    ///
    /// - Parameters:
    ///   - tdp: 机型最大功耗（用户在设置里调整，默认 45W）。
    ///   - usage: CPU 使用率 0...1，越界会夹取到单位区间。
    public static func watts(tdp: Double, usage: Double) -> Double {
        let u = max(0, min(1, usage))
        let cpuPower = tdp * (cpuIdleFactor + cpuLoadFactor * u)
        let platformPower = platformBase + platformLoad * u
        return cpuPower + platformPower
    }
}
