import AppKit
import SwiftUI
import MacBatteryCore

/// 电池数据分析窗口：当前指标卡片 + 温度 / 容量 / 剩余时间趋势。
@MainActor
final class BatteryAnalysisPanelController: NSWindowController {

    /// 标准初始化（仅持有窗口，无额外依赖）。
    override init(window: NSWindow?) {
        super.init(window: window)
    }

    /// 创建分析窗口（首次调用后复用）。
    static func makeIfNeeded(existing: BatteryAnalysisPanelController?,
                             logger: PowerLogger,
                             healthLogger: BatteryHealthLogger)
        -> BatteryAnalysisPanelController {
        if let existing { return existing }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = L("window.battery_analysis")
        panel.isReleasedWhenClosed = false
        // 失焦不隐藏 / 不关闭：否则点击桌面或其它窗口时会闪退。
        panel.hidesOnDeactivate = false
        // 持续上报鼠标移动事件，供图表悬停十字准线与数值浮层使用。
        panel.acceptsMouseMovedEvents = true
        // 普通窗口层级：不做置顶，避免遮挡其它应用。
        panel.collectionBehavior = []
        panel.contentMinSize = NSSize(width: 620, height: 440)

        let hosting = NSHostingView(rootView: BatteryAnalysisView(logger: logger,
                                                                 healthLogger: healthLogger))
        hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 500)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        let controller = BatteryAnalysisPanelController(window: panel)
        controller.shouldCascadeWindows = true
        return controller
    }

    /// 语言切换后刷新窗口标题（窗口内文案由 `LocalizationManager` 驱动自动重绘）。
    func refreshLocalizedText() {
        window?.title = L("window.battery_analysis")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
