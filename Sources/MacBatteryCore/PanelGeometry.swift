import Foundation

/// 位置预设：屏幕四角。
public enum Corner: Int, CaseIterable {
    case topRight, topLeft, bottomRight, bottomLeft

    public var label: String {
        switch self {
        case .topRight: return "右上角"
        case .topLeft: return "左上角"
        case .bottomRight: return "右下角"
        case .bottomLeft: return "左下角"
        }
    }
}

/// 尺寸预设：小 / 中 / 大（相对基础尺寸的缩放）。
public enum SizePreset: Int, CaseIterable {
    case small, medium, large

    public var label: String { ["小", "中", "大"][rawValue] }
    public var scale: CGFloat { [0.8, 1.0, 1.3][rawValue] }
}

/// 挂件定位的纯几何计算。
///
/// 抽成无副作用的纯函数，是为了能脱离 AppKit 单测 ——
/// 这是 U-04（角落锚定）修复的回归护栏：四角 × scale{0.8,1.0,1.3} × margin 的
/// 组合矩阵在 `swift test` 里穷举，改动定位算法不再依赖人工观察。
public enum PanelGeometry {

    /// 面板外边距：可见底盘与屏幕边缘保持 20pt，再扣除四周 glowMargin × scale 的透明余量。
    /// 当前三档 scale（0.8 / 1.0 / 1.3）代入 glowMargin=6 均为正值。
    public static func margin(glowMargin: CGFloat, scale: CGFloat) -> CGFloat {
        20 - glowMargin * scale
    }

    /// 给定角落、可见区域、窗口尺寸与外边距，计算窗口原点。
    ///
    /// 纯计算：不触碰窗口、不读屏幕。调用方自行处理「无可用屏幕」的情况。
    public static func origin(corner: Corner,
                              visibleFrame: CGRect,
                              size: CGSize,
                              margin: CGFloat) -> CGPoint {
        switch corner {
        case .topRight:
            return CGPoint(x: visibleFrame.maxX - size.width - margin,
                           y: visibleFrame.maxY - size.height - margin)
        case .topLeft:
            return CGPoint(x: visibleFrame.minX + margin,
                           y: visibleFrame.maxY - size.height - margin)
        case .bottomRight:
            return CGPoint(x: visibleFrame.maxX - size.width - margin,
                           y: visibleFrame.minY + margin)
        case .bottomLeft:
            return CGPoint(x: visibleFrame.minX + margin,
                           y: visibleFrame.minY + margin)
        }
    }
}
