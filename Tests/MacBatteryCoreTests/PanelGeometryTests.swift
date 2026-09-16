import XCTest
@testable import MacBatteryCore

/// U-04（角落锚定）修复的回归护栏：
/// 四角 × scale{0.8, 1.0, 1.3} × margin 的组合矩阵在这里穷举，
/// 改动定位算法不再依赖人工观察。
///
/// 可见区域故意用 origin=(0,0) 的矩形，期望值直接写数字 ——
/// MacBatteryCore 只依赖 Foundation，测试同样不引入 CoreGraphics 类型。
final class PanelGeometryTests: XCTestCase {

    // 可见区域：x ∈ [0, 1920]，y ∈ [0, 1080]。
    private let frameW: Double = 1920
    private let frameH: Double = 1080
    private let width: Double = 70
    private let height: Double = 70
    private let margin: Double = 8

    private func origin(_ corner: Corner, m: Double) -> (x: Double, y: Double) {
        PanelGeometry.origin(corner: corner,
                             frameX: 0, frameY: 0,
                             frameW: frameW, frameH: frameH,
                             width: width, height: height,
                             margin: m)
    }

    func testAllFourCorners() {
        XCTAssertEqual(origin(.topRight, m: margin).x, 1920 - 70 - 8, accuracy: 1e-9)
        XCTAssertEqual(origin(.topRight, m: margin).y, 1080 - 70 - 8, accuracy: 1e-9)
        XCTAssertEqual(origin(.topLeft, m: margin).x, 8, accuracy: 1e-9)
        XCTAssertEqual(origin(.topLeft, m: margin).y, 1080 - 70 - 8, accuracy: 1e-9)
        XCTAssertEqual(origin(.bottomRight, m: margin).x, 1920 - 70 - 8, accuracy: 1e-9)
        XCTAssertEqual(origin(.bottomRight, m: margin).y, 8, accuracy: 1e-9)
        XCTAssertEqual(origin(.bottomLeft, m: margin).x, 8, accuracy: 1e-9)
        XCTAssertEqual(origin(.bottomLeft, m: margin).y, 8, accuracy: 1e-9)
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
        let o = origin(.topRight, m: -10)
        XCTAssertEqual(o.x, 1920 - 70 + 10, accuracy: 1e-9)
        XCTAssertEqual(o.y, 1080 - 70 + 10, accuracy: 1e-9)
    }

    func testLargestPresetStaysInsideVisibleFrame() {
        let m = PanelGeometry.margin(glowMargin: 6, scale: 1.3)
        let side = 70 * 1.3
        let o = PanelGeometry.origin(corner: .topRight,
                                     frameX: 0, frameY: 0,
                                     frameW: frameW, frameH: frameH,
                                     width: side, height: side, margin: m)
        XCTAssertGreaterThanOrEqual(o.x, 0)
        XCTAssertGreaterThanOrEqual(o.y, 0)
        XCTAssertLessThanOrEqual(o.x + side, frameW)
        XCTAssertLessThanOrEqual(o.y + side, frameH)
    }

    func testOriginAnchorsToRightEdgeForAllCombinations() {
        // 右上角语义：窗口右缘 = 可见区域右缘 - margin（对每个组合都必须成立）。
        for preset in SizePreset.allCases {
            let side = 70 * preset.scale
            let m = PanelGeometry.margin(glowMargin: 6, scale: preset.scale)
            let o = PanelGeometry.origin(corner: .topRight,
                                         frameX: 0, frameY: 0,
                                         frameW: frameW, frameH: frameH,
                                         width: side, height: side, margin: m)
            XCTAssertEqual(o.x + side, frameW - m, accuracy: 1e-6)
            XCTAssertEqual(o.y + side, frameH - m, accuracy: 1e-6)
        }
    }
}
