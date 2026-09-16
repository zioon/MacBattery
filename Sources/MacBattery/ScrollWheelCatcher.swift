import SwiftUI
import AppKit

// MARK: - 滚轮捕获（NSView 桥接）

/// 捕获滚动 + 鼠标悬停事件并回调给 SwiftUI。
/// dx/dy 为带符号滚动位移，option 表示是否按住 Option；onHover 回传鼠标位置（nil 表示离开）。
///
/// 独立成文件：历史图表与电池健康图表都用它，原先定义在 PowerChartView.swift 里、
/// 被健康图**隐式依赖** —— 删改历史图会连累健康图。
struct ScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (Double, Double, Bool) -> Void
    var onHover: (CGPoint?) -> Void

    func makeNSView(context: Context) -> ScrollCatcherView {
        let v = ScrollCatcherView()
        v.onScroll = onScroll
        v.onHover = onHover
        v.allowedTouchTypes = [.direct, .indirect]
        return v
    }

    func updateNSView(_ nsView: ScrollCatcherView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onHover = onHover
    }
}

final class ScrollCatcherView: NSView {
    var onScroll: ((Double, Double, Bool) -> Void)?
    var onHover: ((CGPoint?) -> Void)?
    private var tracking: NSTrackingArea?

    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let option = event.modifierFlags.contains(.option)
        if dx != 0 || dy != 0 {
            onScroll?(dx, dy, option)
        }
        // 已消费，不冒泡。
    }

    // MARK: 悬停跟踪

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }
}
