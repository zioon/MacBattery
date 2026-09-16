import XCTest
@testable import MacBatteryCore

/// U-04（角落锚定）修复的回归护栏：
/// 四角 × scale{0.8, 1.0, 1.3} × margin 的组合矩阵在这里穷举，
/// 改动定位算法不再依赖人工观察。
final class PanelGeometryTests: XCTestCase {

    private let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let size = CGSize(width: 70, height: 70)
    private let margin: CGFloat = 8

    func testAllFourCorners() {
        XCTAssertEqual(PanelGeometry.origin(corner: .topRight, visibleFrame: frame, size: size, margin: margin),
                       CGPoint(x: 1842, y: 1002))
        XCTAssertEqual(PanelGeometry.origin(corner: .topLeft, visibleFrame: frame, size: size, margin: margin),
                       CGPoint(x: 8, y: 1002))
        XCTAssertEqual(PanelGeometry.origin(corner: .bottomRight, visibleFrame: frame, size: size, margin: margin),
                       CGPoint(x: 1842, y: 8))
        XCTAssertEqual(PanelGeometry.origin(corner: .bottomLeft, visibleFrame: frame, size: size, margin: margin),
                       CGPoint(x: 8, y: 8))
    }

    func testMarginAcrossAllSizePresets() {
        for preset in SizePreset.allCases {
            let m = PanelGeometry.margin(glowMargin: 6, scale: preset.scale)
            XCTAssertGreaterThan(m, 0, "scale \(preset.scale) 的外边距不应为负")
            XCTAssertEqual(m, 20 - 6 * preset.scale, accuracy: 1e-9)
        }
    }

    func testNegativeMarginStillAnchors() {
        // margin 为负（外发光余量大于 20pt 的极端配置）时仍按公式锚定，不产生 NaN。
        let o = PanelGeometry.origin(corner: .topRight, visibleFrame: frame, size: size, margin: -10)
        XCTAssertEqual(o, CGPoint(x: frame.maxX - 70 + 10, y: frame.maxY - 70 + 10))
    }

    func testLargestPresetStaysInsideVisibleFrame() {
        let m = PanelGeometry.margin(glowMargin: 6, scale: 1.3)
        let side: CGFloat = 70 * 1.3
        let o = PanelGeometry.origin(corner: .topRight, visibleFrame: frame,
                                     size: CGSize(width: side, height: side), margin: m)
        XCTAssertGreaterThanOrEqual(o.x, frame.minX)
        XCTAssertGreaterThanOrEqual(o.y, frame.minY)
        XCTAssertLessThanOrEqual(o.x + side, frame.maxX)
        XCTAssertLessThanOrEqual(o.y + side, frame.maxY)
    }

    func testOriginAnchorsToRightEdgeForAllCombinations() {
        // 右上角语义：窗口右缘 = visibleFrame.maxX - margin（对每个组合都必须成立）。
        for preset in SizePreset.allCases {
            let side = 70 * preset.scale
            let m = PanelGeometry.margin(glowMargin: 6, scale: preset.scale)
            let o = PanelGeometry.origin(corner: .topRight, visibleFrame: frame,
                                         size: CGSize(width: side, height: side), margin: m)
            XCTAssertEqual(o.x + side, frame.maxX - m, accuracy: 1e-6)
            XCTAssertEqual(o.y + side, frame.maxY - m, accuracy: 1e-6)
        }
    }
}
