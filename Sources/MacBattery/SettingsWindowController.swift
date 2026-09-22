import AppKit
import SwiftUI
import MacBatteryCore

/// 设置窗口（第四批：从 FloatingPanelController 拆出的单一职责组件）。
///
/// 与两个图表窗口一致，采用 `makeIfNeeded` 复用模式；
/// 原先这段创建逻辑内联在 `openSettings()` 里，写法与图表窗口不一致。
@MainActor
final class SettingsWindowController: NSWindowController {

    /// 创建设置窗口（首次调用后复用）。
    static func makeIfNeeded(existing: SettingsWindowController?,
                             store: SettingsStore,
                             updater: UpdateChecker) -> SettingsWindowController {
        if let existing { return existing }

        let hosting = NSHostingView(rootView: SettingsView(store: store, updater: updater))
        hosting.layout()
        let height = max(420, hosting.fittingSize.height)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: height),
                           styleMask: [.titled, .closable],
                           backing: .buffered,
                           defer: false)
        win.title = L("window.settings")
        win.contentView = hosting
        win.isReleasedWhenClosed = false

        return SettingsWindowController(window: win)
    }

    /// 语言切换后刷新窗口标题与内容高度。
    ///
    /// 高度必须重算：窗口高度是创建时按当时的 `fittingSize` 定的，而换语言会改变说明
    /// 文字的行数（英文更长、换行更多），不重算就会被截断。
    func refreshLocalizedText() {
        guard let window, let hosting = window.contentView else { return }
        window.title = L("window.settings")
        hosting.layoutSubtreeIfNeeded()
        let height = max(420, hosting.fittingSize.height)
        window.setContentSize(NSSize(width: window.frame.width, height: height))
    }

    /// 居中显示并激活应用。
    func showAndActivate() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
