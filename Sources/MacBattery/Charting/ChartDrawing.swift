import SwiftUI

/// 图表的公共绘制原语。
enum ChartDrawing {

    /// 折线描边：两个图表共用同一线宽 / 圆角 / 透明度（原先各写一份）。
    static func strokePoints(_ pts: [CGPoint], color: Color, in layer: GraphicsContext,
                             width: CGFloat = 1.6, opacity: Double = 0.9) {
        guard pts.count >= 2 else { return }
        var path = Path()
        path.move(to: pts[0])
        for pt in pts.dropFirst() { path.addLine(to: pt) }
        layer.stroke(path, with: .color(color.opacity(opacity)),
                     style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}
