import Foundation

/// 位置预设：屏幕四角。
public enum Corner: Int, CaseIterable {
    case topRight, topLeft, bottomRight, bottomLeft

    /// 文案键名（**不是**最终文案）。
    ///
    /// 刻意只给键名、不给译文：本目录是禁止 AppKit / IOKit / SwiftUI 的纯逻辑层，
    /// 做成「给键、由 UI 层翻译」的形态后，定位几何的单测就不会因为语言而变化。
    /// 译文见 `Sources/MacBatteryCore/Resources/<lang>.lproj/Localizable.strings`。
    public var localizationKey: String {
        switch self {
        case .topRight: return "corner.topRight"
        case .topLeft: return "corner.topLeft"
        case .bottomRight: return "corner.bottomRight"
        case .bottomLeft: return "corner.bottomLeft"
        }
    }
}

/// 尺寸预设：小 / 中 / 大（相对基础尺寸的缩放）。
public enum SizePreset: Int, CaseIterable {
    case small, medium, large

    /// 文案键名（**不是**最终文案），理由见 `Corner.localizationKey`。
    public var localizationKey: String {
        switch self {
        case .small: return "size.small"
        case .medium: return "size.medium"
        case .large: return "size.large"
        }
    }

    /// 相对基础尺寸的缩放系数（0.8 / 1.0 / 1.3）。
    ///
    /// ⚠️ 刻意用 Double 而非 CGFloat：Core 层不引入 CoreGraphics 类型，
    /// 否则本模块的 swiftmodule 会交叉引用 CoreFoundation，
    /// 在 Swift 5.10 的 universal 构建里触发编译器崩溃（已实证）。
    public var scale: Double { [0.8, 1.0, 1.3][rawValue] }
}

/// 挂件定位的纯几何计算。
///
/// 抽成无副作用的纯函数，是为了能脱离 AppKit 单测 ——
/// 这是 U-04（角落锚定）修复的回归护栏：四角 × scale{0.8,1.0,1.3} × margin 的
/// 组合矩阵在 `swift test` 里穷举，改动定位算法不再依赖人工观察。
///
/// ⚠️ 本类型全部使用 `Double`：Core 层禁止 CGPoint / CGRect / CGFloat，
/// （AppKit 的 `CGRect.maxX` 等便捷属性同样不可用），调用方负责与 CG 类型互转。
public enum PanelGeometry {

    /// 面板外边距：可见底盘与屏幕边缘保持 20pt，再扣除四周 glowMargin × scale 的透明余量。
    /// 当前三档 scale（0.8 / 1.0 / 1.3）代入 glowMargin=6 均为正值。
    public static func margin(glowMargin: Double, scale: Double) -> Double {
        20 - glowMargin * scale
    }

    /// 给定角落、可见区域（x / y / 宽 / 高）、窗口尺寸（宽 / 高）与外边距，计算窗口原点 (x, y)。
    public static func origin(corner: Corner,
                              frameX: Double, frameY: Double,
                              frameW: Double, frameH: Double,
                              width: Double, height: Double,
                              margin: Double) -> (x: Double, y: Double) {
        let maxX = frameX + frameW
        let maxY = frameY + frameH
        switch corner {
        case .topRight:
            return (x: maxX - width - margin, y: maxY - height - margin)
        case .topLeft:
            return (x: frameX + margin, y: maxY - height - margin)
        case .bottomRight:
            return (x: maxX - width - margin, y: frameY + margin)
        case .bottomLeft:
            return (x: frameX + margin, y: frameY + margin)
        }
    }
}
