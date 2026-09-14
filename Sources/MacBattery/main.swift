import AppKit

/// 应用入口。
///
/// 说明：
/// - 以 SPM 可执行程序运行，不打包 .app，因此使用 `.accessory` 激活策略，
///   只保留浮窗、不出现 Dock 图标。
/// - 如需退出，在终端 Ctrl+C。
let app = NSApplication.shared

final class AppDelegate: NSObject, NSApplicationDelegate {
    fileprivate var windowController: FloatingPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标（纯浮窗工具）。
        app.setActivationPolicy(.accessory)
        windowController = FloatingPanelController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.close()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()