import Foundation

/// 图表交互的纯数学：平移量、缩放系数、右缘钳制、最近样本定位。
///
/// 历史图与电池健康图的交互 handler 结构相同但缩放对象不同
///（历史缩右轴、健康缩多行 y 轴），因此这里只抽共享的数学部分，
/// handler 留在各自视图里 —— 避免为了去重强行引入一个控制器抽象。
enum ChartInteraction {

    /// 把值夹到 [lo, hi]。
    static func bounded(_ f: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(f, lo), hi)
    }

    /// 横向滚动 / 拖拽对应的时间平移量（秒）。绘图宽度过小返回 nil（无可平移）。
    static func panSeconds(dx: Double, plotWidth: Double, timeRange: TimeInterval) -> Double? {
        guard plotWidth > 0 else { return nil }
        return dx / plotWidth * timeRange
    }

    /// 纵向滚动 → 时间窗缩放系数（钳制单次幅度，避免一次滚轮跳变）。
    static func timeZoomFactor(dy: Double) -> Double {
        bounded(exp(Double(-dy) * 0.02), 0.84, 1.19)
    }

    /// Option + 纵向滚动 → y 轴缩放系数。
    static func axesZoomFactor(dy: Double) -> Double {
        bounded(exp(Double(-dy) * 0.015), 0.86, 1.16)
    }

    /// 时间窗缩放：钳制到 [minView, maxView]，只改跨度不移动右缘。
    static func zoomedRange(_ range: TimeInterval, by factor: Double,
                            minView: TimeInterval, maxView: TimeInterval) -> TimeInterval {
        var newRange = range / factor
        if newRange > maxView { newRange = maxView }
        if newRange < minView { newRange = minView }
        return newRange
    }

    /// 时间右缘钳制：上限不越过当前时间 + 12s 采样余量，
    /// 下限不早于最早样本 + 20s（保证右缘附近始终有数据可画）。
    static func clampedEnd(_ d: Date, now: Date, earliest: Date?) -> Date {
        let cap = now.addingTimeInterval(12)
        if d > cap { return cap }
        if let e = earliest, d < e.addingTimeInterval(20) { return e.addingTimeInterval(20) }
        return d
    }

    /// 序列中时间不超过 target 的最近一条（二分查找；样本须按时间升序）。
    /// 历史图与电池健康图共用同一实现，元素类型由时间戳闭包解耦。
    static func nearestSample<T>(upTo target: Double, in arr: [T], timestamp: (T) -> Date) -> T? {
        guard !arr.isEmpty else { return nil }
        var lo = 0, hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if timestamp(arr[mid]).timeIntervalSince1970 <= target { lo = mid + 1 } else { hi = mid }
        }
        let idx = lo - 1
        return idx >= 0 ? arr[idx] : nil
    }
}
