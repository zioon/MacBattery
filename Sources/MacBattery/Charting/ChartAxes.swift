import SwiftUI
import MacBatteryCore

/// 图表的刻度与格式化工具。
///
/// 原先历史图与电池健康图各写一份几乎相同的实现
///（`niceStep` / `niceTimeStep` / `yTicks` / `formatY` / `fmtVal` / `timeText`），
/// 现统一为单一来源；两图只有时间刻度的**最小步长**不同，用参数区分。
enum ChartAxes {

    // MARK: - 刻度步长

    /// 单调的 1-2-5 刻度步长：span 增大时步长只增不减，保证轴范围与刻度对齐、稳定。
    /// 右轴范围取整（niceViewport）与刻度绘制（yTicks）共用同一实现。
    static func niceStep(_ span: Double, target: Int) -> Double {
        guard span > 0 else { return 1 }
        let raw = span / Double(max(1, target))
        let mag = pow(10, floor(log10(raw)))
        let residual = raw / mag
        let step: Double
        if residual < 1 { step = 1 }
        else if residual < 2 { step = 2 }
        else if residual < 2.5 { step = 2.5 }
        else if residual < 5 { step = 5 }
        else { step = 10 }
        return step * mag
    }

    /// 时间轴刻度步长：按 span / 6 选一个不小于 `minimumStep` 的候选。
    /// 历史图支持亚分钟刻度（minimumStep = 1），
    /// 电池健康图数据变化极慢、最小 60s（minimumStep = 60）。
    static func niceTimeStep(_ span: Double, minimumStep: Double = 1) -> Double {
        let candidates: [Double] = [1, 2, 5, 10, 15, 30,
                                    60, 120, 300, 600, 900, 1800,
                                    3600, 7200, 14400, 21600, 36000, 43200, 86400]
            .filter { $0 >= minimumStep }
        let target = span / 6
        for c in candidates where c >= target { return c }
        return candidates.last ?? 86400
    }

    // MARK: - 刻度与格式化

    /// 纵轴刻度：以 1-2-5 步长从 minV 向上取整铺到 maxV。
    static func yTicks(_ minV: Double, _ maxV: Double) -> [Double] {
        let span = maxV - minV
        guard span > 0 else { return [] }
        let step = niceStep(span, target: 5)
        var out: [Double] = []
        var v = ceil(minV / step) * step
        while v <= maxV + 1e-9 {
            out.append(v)
            v += step
        }
        return out
    }

    /// 轴刻度文本：整数或大数取整显示，其余一位小数。
    ///
    /// 数字本身走区域化格式化：原先的 `String(format: "%.1f")` 不认区域，
    /// 在德语等以逗号作小数点的区域会显示错误。
    static func formatY(_ v: Double) -> String {
        if abs(v - v.rounded()) < 1e-6 || v.magnitude >= 100 {
            return LocalizedFormat.number(v, decimals: 0)
        }
        return LocalizedFormat.number(v, decimals: 1)
    }

    /// 悬浮 / 图例的数值文本：整数取整显示，其余一位小数。
    static func fmtVal(_ v: Double) -> String {
        if v.magnitude >= 100 || v == v.rounded() {
            return LocalizedFormat.number(v, decimals: 0)
        }
        return LocalizedFormat.number(v, decimals: 1)
    }

    /// 时长文本：秒 / 分钟 / 小时 / 天。
    ///
    /// 秒与分钟带数量词，英文需要区分单复数（`.one` / `.other`）；小时与天用一位小数，
    /// 先按区域格式化数字再代入 `%@`。
    static func timeText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return LP("duration.seconds", count: Int(seconds)) }
        if seconds < 3600 { return LP("duration.minutes", count: Int(seconds / 60)) }
        if seconds < 86400 {
            return L("duration.hours", LocalizedFormat.number(seconds / 3600, decimals: 1))
        }
        return L("duration.days", LocalizedFormat.number(seconds / 86400, decimals: 1))
    }
}
