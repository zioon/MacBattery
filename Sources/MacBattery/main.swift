import AppKit

/// 应用入口。
///
/// 说明：
/// - 以 SPM 可执行程序运行，不打包 .app，因此使用 `.accessory` 激活策略，
///   只保留浮窗、不出现 Dock 图标。
/// - 如需退出，在终端 Ctrl+C。
let app = NSApplication.shared

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: FloatingPanelController?

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

// 顶层代码默认在非隔离上下文；AppDelegate 是 @MainActor，
// 因此在 main 里显式断言主线程，再创建并运行应用。
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}