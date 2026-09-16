import SwiftUI

/// 图表绘图区：由外尺寸与四边留白推导出绘图宽高与边界坐标。
///
/// 原先历史图（PlotRect）与电池健康图（HealthPlot）各有一份几乎相同的定义，
/// 后者多出上/下两个分区的划分 —— 现统一为一个类型，分区由调用方按需计算。
struct ChartPlot {
    let outer: CGSize
    let left, right, top, bottom: Double

    var plotW: Double { max(10, outer.width - left - right) }
    var plotH: Double { max(10, outer.height - top - bottom) }

    var minX: Double { left }
    var minY: Double { top }
    var maxX: Double { left + plotW }
    var maxY: Double { top + plotH }

    init(outer: CGSize, left: Double, right: Double, top: Double, bottom: Double) {
        self.outer = outer
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }
}

/// 电池健康图的上下分区：上图（容量 / 健康度）约占 62%，间隔 8pt，下图为循环次数。
/// 历史图是单区绘图，不使用这些属性。
extension ChartPlot {
    var gap: Double { 8 }
    var topRatio: Double { 0.62 }
    var topH: Double { max(10, plotH * topRatio) }
    var bottomH: Double { max(10, plotH - topH - gap) }
    /// 上图区域（容量 / 健康度）。
    var topY: Double { top }
    var topBottom: Double { top + topH }
    /// 下图区域（循环次数）。
    var bottomY: Double { top + topH + gap }
    var bottomBottom: Double { top + plotH }
}
