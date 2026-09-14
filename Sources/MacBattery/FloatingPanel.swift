import AppKit
import SwiftUI

/// 置顶、透明、鼠标穿透的小浮窗（NSPanel）。
/// 负责创建挂件、管理设置、菜单栏入口与设置窗口。
@MainActor
final class FloatingPanelController: NSWindowController {

    private let settings: SettingsStore
    private let monitor: PowerMonitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var settingsWindow: NSWindow?
    private var moveObserver: NSObjectProtocol?

    /// 挂件在 scale=1 时的基础宽高（与 PowerHUDView 保持一致）。
    private let baseWidth: CGFloat = 208
    private let baseHeight: CGFloat = 64

    init() {
        settings = SettingsStore()
        monitor = PowerMonitor(settings: settings)
        super.init(window: nil)

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: baseWidth, height: baseHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.window = panel

        monitor.start()
        settings.onChange = { [weak self] in self?.applySettings() }

        buildStatusItem()
        applySettings()
        panel.makeKeyAndOrderFront(nil)
        observeWindowMove(panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        Task { @MainActor [weak self] in self?.monitor.stop() }
    }

    // MARK: - 应用设置

    /// 按当前设置重建尺寸/内容、定位、设置穿透。
    private func applySettings() {
        guard let panel = window as? NSPanel else { return }

        let scale = (SizePreset(rawValue: settings.sizeRaw) ?? .medium).scale
        let width = baseWidth * scale
        let height = baseHeight * scale

        let hosting = NSHostingView(rootView: PowerHUDView(monitor: monitor, scale: scale))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.autoresizingMask = []

        panel.contentView = hosting
        panel.setContentSize(NSSize(width: width, height: height))

        panel.ignoresMouseEvents = settings.passthrough
        panel.isMovableByWindowBackground = !settings.passthrough

        positionPanel(panel)
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let vis = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 20

        let origin: NSPoint
        if settings.hasCustom {
            origin = NSPoint(x: settings.customX, y: settings.customY)
        } else {
            switch Corner(rawValue: settings.cornerRaw) ?? .topRight {
            case .topRight:
                origin = NSPoint(x: vis.maxX - size.width - margin,
                                 y: vis.maxY - size.height - margin)
            case .topLeft:
                origin = NSPoint(x: vis.minX + margin,
                                 y: vis.maxY - size.height - margin)
            case .bottomRight:
                origin = NSPoint(x: vis.maxX - size.width - margin,
                                 y: vis.minY + margin)
            case .bottomLeft:
                origin = NSPoint(x: vis.minX + margin,
                                 y: vis.minY + margin)
            }
        }
        panel.setFrameOrigin(origin)
    }

    private func observeWindowMove(_ panel: NSPanel) {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] note in
            guard let w = note.object as? NSWindow else { return }
            Task { @MainActor [weak self] in
                self?.settings.rememberDrag(x: w.frame.origin.x, y: w.frame.origin.y)
            }
        }
    }

    // MARK: - 菜单栏

    private func buildStatusItem() {
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.circle.fill",
                                           accessibilityDescription: "MacBattery")

        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        // 位置子菜单
        let posItem = NSMenuItem()
        posItem.title = "位置"
        let posSub = NSMenu()
        for c in Corner.allCases {
            let it = NSMenuItem(title: c.label, action: #selector(chooseCorner(_:)), keyEquivalent: "")
            it.tag = c.rawValue
            it.target = self
            it.state = (!settings.hasCustom && settings.cornerRaw == c.rawValue) ? .on : .off
            posSub.addItem(it)
        }
        posItem.submenu = posSub
        menu.addItem(posItem)

        // 大小子菜单
        let sizeItem = NSMenuItem()
        sizeItem.title = "大小"
        let sizeSub = NSMenu()
        for p in SizePreset.allCases {
            let it = NSMenuItem(title: p.label, action: #selector(chooseSize(_:)), keyEquivalent: "")
            it.tag = p.rawValue
            it.target = self
            it.state = (settings.sizeRaw == p.rawValue) ? .on : .off
            sizeSub.addItem(it)
        }
        sizeItem.submenu = sizeSub
        menu.addItem(sizeItem)

        // 鼠标穿透开关
        let passthroughItem = NSMenuItem(title: "鼠标穿透", action: #selector(togglePassthrough(_:)), keyEquivalent: "")
        passthroughItem.target = self
        passthroughItem.state = settings.passthrough ? .on : .off
        menu.addItem(passthroughItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 MacBattery", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
                               styleMask: [.titled, .closable],
                               backing: .buffered,
                               defer: false)
            win.title = "MacBattery 设置"
            win.contentView = NSHostingView(rootView: SettingsView(store: settings))
            win.isReleasedWhenClosed = false
            settingsWindow = win
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func chooseCorner(_ sender: NSMenuItem) {
        settings.cornerRaw = sender.tag
        settings.hasCustom = false
        settings.commit()
        rebuildMenuCheckmarks()
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        settings.sizeRaw = sender.tag
        settings.commit()
        rebuildMenuCheckmarks()
    }

    @objc private func togglePassthrough(_ sender: NSMenuItem) {
        settings.passthrough.toggle()
        settings.commit()
        sender.state = settings.passthrough ? .on : .off
        rebuildMenuCheckmarks()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func rebuildMenuCheckmarks() {
        buildStatusItem()
    }
}

// MARK: - FloatingPanel（置顶 + 穿透）

final class FloatingPanel: NSPanel {

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer deferred: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: styleMask,
                   backing: backing,
                   defer: deferred)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
}