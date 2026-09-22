import SwiftUI
import MacBatteryCore

/// 悬停浮层数据：竖线位置 + 该时刻各系列取值。
///
/// 历史图与电池健康图共用（原先两处各定义一份、绘制代码几乎逐字相同）。
struct ChartHoverInfo {
    /// 竖线在绘图区内的 x 坐标。
    let x: Double
    let date: Date
    let rows: [Row]

    struct Row {
        let color: Color
        let title: String
        let value: String
    }
}

enum ChartHover {

    /// 悬浮层的时间字段模板：随查看跨度变粗（同一规则两图共用）。
    /// 交给系统按区域解析，避免写死小时制 —— 原先硬编码 "HH:mm"，12 小时制区域会显示成 24 小时制。
    static func timeTemplate(span: Double) -> String {
        if span >= 86400 { return "MMdj" }
        if span >= 3600 { return "jm" }
        return "jms"
    }

    /// 绘制悬停竖线 + 该时刻数值浮层。
    ///
    /// - Parameters:
    ///   - yTop / yBottom: 竖线贯穿的纵向范围（历史图为整个绘图区，
    ///     电池健康图跨上 / 下两个分区）。
    ///   - span: 当前查看的时间跨度（决定时间文本格式）。
    ///   - lineOpacity: 竖线透明度（历史 0.55、健康 0.5，保留各自观感）。
    static func draw(_ info: ChartHoverInfo, in ctx: GraphicsContext,
                     plot: ChartPlot, yTop: Double, yBottom: Double,
                     span: Double, lineOpacity: Double) {
        let x = CGFloat(info.x)
        guard x >= plot.minX, x <= plot.maxX else { return }

        // 竖线
        var vp = Path()
        vp.move(to: CGPoint(x: x, y: yTop))
        vp.addLine(to: CGPoint(x: x, y: yBottom))
        ctx.stroke(vp, with: .color(.white.opacity(lineOpacity)), lineWidth: 1)

        // 浮层放竖线偏向空白一侧。
        let goRight = x < plot.minX + plot.plotW / 2
        let anchor: UnitPoint = goRight ? .leading : .trailing
        let bx = goRight ? x + 10 : x - 10

        let timeText = Text(LocalizedFormat.date(info.date, template: timeTemplate(span: span)))
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
        ctx.draw(timeText, at: CGPoint(x: bx, y: yTop + 8), anchor: anchor)

        var yy = yTop + 26
        for row in info.rows {
            let line = Text("\(row.title)  \(row.value)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(row.color)
            ctx.draw(line, at: CGPoint(x: bx, y: yy), anchor: anchor)
            yy += 15
        }
    }
}
