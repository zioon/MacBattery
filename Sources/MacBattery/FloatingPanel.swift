import AppKit
import SwiftUI

/// 置顶、透明、鼠标穿透的小浮窗（NSPanel）。
final class FloatingPanelController: NSWindowController {

    private let monitor = PowerMonitor()

    init() {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 148, height: 184),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)

        monitor.start()

        let hosting = NSHostingView(rootView: PowerHUDView(monitor: monitor))
        panel.contentView = hosting

        placePanel(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        monitor.stop()
    }

    /// 把面板放到屏幕右上角，横向与屏幕边缘留出固定间距。
    private func placePanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 28

        let origin = NSPoint(
            x: visible.maxX - panel.frame.width - margin,
            y: visible.maxY - panel.frame.height - margin
        )
        panel.setFrameOrigin(origin)
    }
}

/// 简单的 置顶 + 穿透 面板。
final class FloatingPanel: NSPanel {

    init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: styleMask,
                   backing: backing,
                   defer: defer)

        // 置顶于所有窗口之上，含全屏 / 所有桌面空间。
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 窗口本身不参与焦点管理，避免抢键鼠。
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        // 不可见激活状态下也能一直显示。
        isReleasedWhenClosed = false
    }
}