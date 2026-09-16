import AppKit
import SwiftUI
import MacBatteryCore

/// 置顶、透明、鼠标穿透的小浮窗（NSPanel）。
/// 负责创建挂件、管理设置、菜单栏入口与设置窗口。
@MainActor
final class FloatingPanelController: NSWindowController {

    private let settings: SettingsStore
    private let monitor: PowerMonitor
    private let logger = PowerLogger()
    private let healthLogger = BatteryHealthLogger()
    private var chartController: PowerChartPanelController?
    private var healthPanelController: BatteryHealthPanelController?
    private let updater = UpdateChecker()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var settingsWindow: NSWindow?
    private var moveObserver: NSObjectProtocol?

    /// 最近一次「程序化」移动（applySettings 定位）写入的窗口原点。仅主线程读写。
    /// didMove 观察者据此识别并忽略由程序化定位触发的通知，避免把程序化移动误记为
    /// 用户拖拽（否则 `hasCustom` 会被错误写回 true，导致角落锚定丢失）。
    private var lastProgrammaticOrigin: NSPoint?

    /// 当前渲染 HUD 用的缩放档位。未变化时不重建视图树（见 applySettings 的说明）。
    private var renderedScale: CGFloat?

    /// 挂件在 scale=1 时的基础宽高（与 PowerHUDView 保持一致）。
    /// 可见底盘为 58×58，四周各留 6pt 透明余量供充电外发光扩散，避免被窗口边界裁切。
    private let baseWidth: CGFloat = 70
    private let baseHeight: CGFloat = 70
    /// 面板四周的透明留白（与 PowerHUDView.glowMargin 一致），定位时需扣除。
    private let glowMargin: CGFloat = 6

    init() {
        settings = SettingsStore()
        monitor = PowerMonitor(settings: settings, logger: logger)
        super.init(window: nil)

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: baseWidth, height: baseHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.window = panel

        monitor.start()
        // 电池健康日志随应用常驻运行，即使不开图表也能持续积累健康历史。
        healthLogger.start()
        settings.onChange = { [weak self] in self?.applySettings() }

        buildStatusItem()
        applySettings()
        panel.makeKeyAndOrderFront(nil)
        observeWindowMove(panel)

        // 启动时静默检查一次更新：仅在发现并下载到新版本时才提示，不打扰日常使用。
        updater.checkForUpdates(interactive: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        // 只做能安全同步完成的事：摘除通知观察者。
        // 原先这里还有 `Task { @MainActor [weak self] in self?.monitor.stop() ... }`，
        // 但 deinit 时引用计数已为 0，`[weak self]` 必然为 nil —— 那条清理路径从未执行过。
        // 真正的清理改由显式入口 `shutdown()` 承担（见下）。
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 显式清理入口，由 AppDelegate.applicationWillTerminate 调用。
    /// 原先放在 deinit 里的 `Task { @MainActor [weak self] }` 因 weak self 必为 nil 而从未执行，
    /// 导致 PowerLogger.stop() 的最终 flushPending() 不跑、timer 不取消、RunLoop 源不摘除。
    ///
    /// 已知取舍：**不引入** SIGINT/SIGTERM 信号处理器做"优雅退出" —— README 把终端 Ctrl+C
    /// 作为 `swift run` 的退出方式，一旦 `NSApp.terminate` 在 `.accessory` 激活策略下行为异常，
    /// 就会破坏用户现有的退出方式；而收益只是挽回最多 1 秒的待落盘样本
    ///（`PowerLogger` 每 1 秒 flush 一次）。风险收益不成比例，已评估并接受：
    /// **Ctrl+C 直杀进程会丢最多 1 秒样本。**
    @MainActor
    func shutdown() {
        // 解绑设置回调：退出过程中设置若再变化，不应再触发 re-layout / 触发采样。
        settings.onChange = nil
        monitor.stop()      // 内部会 logger.stop() → flushPending()
        healthLogger.stop()
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
            moveObserver = nil
        }
        window?.close()
    }

    // MARK: - 应用设置

    /// 按当前设置重建尺寸/内容、定位、设置穿透。
    private func applySettings() {
        guard let panel = window as? NSPanel else { return }

        let scale = (SizePreset(rawValue: settings.sizeRaw) ?? .medium).scale
        let width = baseWidth * scale
        let height = baseHeight * scale

        // 仅在尺寸档位变化时重建整棵 HUD 视图树：拖动 TDP 滑块会高频触发 commit，
        // 而 TDP / 穿透开关都不参与 PowerHUDView 构造（参数只有 monitor + scale），
        // 原先每次 commit 都重建一棵树纯属浪费；PowerHUDView 自己持有 @ObservedObject
        // monitor，运行期数值更新由它驱动，与这里无关。
        if renderedScale != scale {
            renderedScale = scale
            let hosting = NSHostingView(rootView: PowerHUDView(monitor: monitor, scale: scale))
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            hosting.autoresizingMask = []
            panel.contentView = hosting
        }

        panel.ignoresMouseEvents = settings.passthrough
        panel.isMovableByWindowBackground = !settings.passthrough

        let newSize = NSSize(width: width, height: height)
        let newOrigin = computeOrigin(size: newSize) ?? panel.frame.origin
        // 合并为单次 setFrame：同时设定尺寸与原点，消除"尺寸已变、原点未随"的中间态
        // ——角落锚定的挂件会瞬间偏离角落，合并后该中间态不存在。
        // 通知条数由不确定变为确定 1 条（旧实现先 setContentSize 再 setFrameOrigin 分两步）。
        // 记录本次程序化原点，供 didMove 观察者据此忽略程序化移动。
        lastProgrammaticOrigin = newOrigin
        panel.setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
    }

    /// 计算面板应在的窗口原点（无副作用，不触碰窗口）。无可用屏幕时返回 nil。
    /// 几何计算抽到 MacBatteryCore/PanelGeometry（纯函数，U-04 的回归护栏）；
    /// 本方法只负责「取屏幕 + 处理无屏幕的回退」这一 AppKit 相关部分。
    private func computeOrigin(size: NSSize) -> NSPoint? {
        guard let screen = NSScreen.main else { return nil }
        let vis = screen.visibleFrame
        // 面板四周含 glowMargin 的透明留白，扣除后可见底盘才与屏幕边缘保持 20pt。
        let scale = (SizePreset(rawValue: settings.sizeRaw) ?? .medium).scale
        let margin = PanelGeometry.margin(glowMargin: glowMargin, scale: scale)

        if settings.hasCustom {
            return NSPoint(x: settings.customX, y: settings.customY)
        }
        let corner = Corner(rawValue: settings.cornerRaw) ?? .topRight
        // NSPoint / NSSize 在 macOS 上就是 CGPoint / CGSize 的别名，可直接传给纯几何层。
        return PanelGeometry.origin(corner: corner,
                                    visibleFrame: vis,
                                    size: size,
                                    margin: margin)
    }

    private func observeWindowMove(_ panel: NSPanel) {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] note in
            guard let w = note.object as? NSWindow else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let origin = w.frame.origin
                // 「程序化移动」标记的消费策略：命中则忽略并**保留**，不命中才清除。
                // 无论 AppKit 是否对程序化 setFrame 发出 didMove 通知，都不会产生错误行为 ——
                //  · 若发了通知：命中标记（差值 ≤ 0.5pt）视为程序化移动，忽略不记录，且保留标记，
                //    使一轮内多次程序化 setFrame 产生的多条通知都能被逐一正确忽略；
                //  · 若没发通知：标记一直保留，直到用户首次真实拖拽（值不符）才被清除并正确记录。
                if let expected = self.lastProgrammaticOrigin,
                   abs(origin.x - expected.x) <= 0.5,
                   abs(origin.y - expected.y) <= 0.5 {
                    return // 由程序化定位引起：忽略本次通知，保留标记
                }
                // 不命中（含本就没有标记）→ 清除标记并按用户拖拽记录。
                self.lastProgrammaticOrigin = nil
                self.settings.rememberDrag(x: origin.x, y: origin.y)
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

        // 历史图表
        let chartItem = NSMenuItem(title: "历史图表…", action: #selector(openChart), keyEquivalent: "g")
        chartItem.target = self
        menu.addItem(chartItem)

        // 电池健康（独立窗口）
        let healthItem = NSMenuItem(title: "电池健康…", action: #selector(openHealthChart), keyEquivalent: "h")
        healthItem.target = self
        menu.addItem(healthItem)

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
        let updateItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 MacBattery", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingView(rootView: SettingsView(store: settings, updater: updater))
            hosting.layout()
            let height = max(420, hosting.fittingSize.height)
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: height),
                               styleMask: [.titled, .closable],
                               backing: .buffered,
                               defer: false)
            win.title = "MacBattery 设置"
            win.contentView = hosting
            win.isReleasedWhenClosed = false
            settingsWindow = win
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openChart() {
        chartController = PowerChartPanelController.makeIfNeeded(existing: chartController,
                                                                 logger: logger,
                                                                 healthLogger: healthLogger)
        chartController?.showWindow(nil)
        window?.orderFront(nil) // 保证挂件仍在菜单之上可见
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openHealthChart() {
        // 打开健康窗口时立即采样一次，保证当前值即刻可见并落盘；
        // 并切换到加密采样（5s），让图例数值在查看期间跟手（关闭后自动回到常驻 60s）。
        healthLogger.recordNow()
        healthLogger.setWindowVisible(true)
        healthPanelController = BatteryHealthPanelController.makeIfNeeded(existing: healthPanelController,
                                                                          healthLogger: healthLogger)
        healthPanelController?.showWindow(nil)
        window?.orderFront(nil) // 保证挂件仍在菜单之上可见
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

    @objc private func checkForUpdates() {
        updater.checkForUpdates(interactive: true)
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