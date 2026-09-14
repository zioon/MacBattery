import AppKit
import SwiftUI

/// 历史图表窗口：一个可缩放 / 拖拽的多系列折线图容器。
@MainActor
final class PowerChartPanelController: NSWindowController {

    /// 电池健康日志（一并注入，供图表后续展示健康数据时使用）。
    private let healthLogger: BatteryHealthLogger

    override init(window: NSWindow?, healthLogger: BatteryHealthLogger) {
        self.healthLogger = healthLogger
        super.init(window: window)
    }

    /// 创建图表窗口（首次调用后复用）。
    static func makeIfNeeded(existing: PowerChartPanelController?,
                            logger: PowerLogger,
                            healthLogger: BatteryHealthLogger)
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
        // 悬浮不隐藏 / 不关闭：否则点击桌面或其它窗口时图表会闪退。
        panel.hidesOnDeactivate = false
        // 持续上报鼠标移动事件，供图表十字准线与数值浮层使用。
        panel.acceptsMouseMovedEvents = true
        // 普通窗口层级：不做置顶，避免遮挡其它应用；需要看趋势时再手动切换。
        // 多桌面（Spaces）下仅存在于当前桌面，切换桌面时正常跟随，不占据每个桌面。
        panel.collectionBehavior = []
        panel.contentMinSize = NSSize(width: 560, height: 320)

        let hosting = NSHostingView(rootView: PowerChartView(logger: logger))
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 420)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        let controller = PowerChartPanelController(window: panel, healthLogger: healthLogger)
        controller.shouldCascadeWindows = true
        return controller
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}