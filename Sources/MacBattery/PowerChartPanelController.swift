import AppKit
import SwiftUI

/// 历史图表窗口：一个可缩放 / 拖拽的多系列折线图容器。
@MainActor
final class PowerChartPanelController: NSWindowController {

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    /// 创建图表窗口（首次调用后复用）。
    static func makeIfNeeded(existing: PowerChartPanelController?, logger: PowerLogger)
        -> PowerChartPanelController {
        if let existing { return existing }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "MacBattery 历史图表"
        panel.isReleasedWhenClosed = false
        // 失焦不隐藏 / 不关闭：否则点击桌面或其它窗口时图表会闪退。
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 560, height: 320)

        let hosting = NSHostingView(rootView: PowerChartView(logger: logger))
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 420)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        let controller = PowerChartPanelController(window: panel)
        controller.shouldCascadeWindows = true
        return controller
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}