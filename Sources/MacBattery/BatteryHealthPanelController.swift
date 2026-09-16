import AppKit
import SwiftUI

/// 电池健康图表窗口：一个独立的可缩放 / 拖拽窗口，展示当前最大容量 / 设计容量 / 电池健康度 / 循环次数。
@MainActor
final class BatteryHealthPanelController: NSWindowController {

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    /// 创建健康图表窗口（首次调用后复用）。
    static func makeIfNeeded(existing: BatteryHealthPanelController?, healthLogger: BatteryHealthLogger)
        -> BatteryHealthPanelController {
        if let existing { return existing }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "MacBattery 电池健康"
        panel.isReleasedWhenClosed = false
        // 失焦不隐藏 / 不关闭：否则点击桌面或其它窗口时图表会闪退。
        panel.hidesOnDeactivate = false
        // 普通窗口层级：不做置顶，避免遮挡其它应用；需要看趋势时再手动切换。
        // 多桌面（Spaces）下仅存在于当前桌面，切换桌面时正常跟随，不占据每个桌面。
        panel.collectionBehavior = []
        panel.contentMinSize = NSSize(width: 560, height: 300)

        let hosting = NSHostingView(rootView: BatteryHealthChartView(healthLogger: healthLogger))
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 420)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        let controller = BatteryHealthPanelController(window: panel)
        controller.shouldCascadeWindows = true

        // 窗口关闭时退出「加密采样」模式（回到常驻 60s），避免无人查看时白白读取。
        // 面板常驻复用（isReleasedWhenClosed = false），观察者只在首次创建时注册一次。
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: panel, queue: .main) { _ in
            Task { @MainActor in healthLogger.setWindowVisible(false) }
        }
        return controller
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}