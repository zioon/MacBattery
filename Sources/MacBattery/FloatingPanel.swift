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
    /// 菜单栏（第四批拆出，见 MenuBarController）。
    private var menuController: MenuBarController!
    /// 设置窗口（第四批拆出，见 SettingsWindowController）。
    private var settingsWindowController: SettingsWindowController?
    private var moveObserver: NSObjectProtocol?

    /// 最近一次「程序化」移动（applySettings 定位）写入的窗口原点。仅主线程读写。
    /// didMove 观察者据此识别并忽略由程序化定位触发的通知，避免把程序化移动误记为
    /// 用户拖拽（否则 `hasCustom` 会被错误写回 true，导致角落锚定丢失）。
    private var lastProgrammaticOrigin: NSPoint?

    /// 当前渲染 HUD 用的缩放档位。未变化时不重建视图树（见 applySettings 的说明）。
    private var renderedScale: CGFloat?

    /// 当前渲染界面所用的语言。切换语言时菜单、窗口标题与挂件视图树都要刷新。
    private var renderedLanguage: AppLanguage?

    /// 最近一次渲染到菜单栏的充电上限配置。
    /// 只在变化时重建菜单：TDP 滑块每次 `commit()` 都重建一次 NSMenu 纯属浪费
    ///（与 `renderedScale` 同一思路）。用两个可选值而不是元组 —— 元组无法参与
    /// `Optional` 的 `==` 比较（元组不满足 `Equatable` 约束）。
    private var renderedChargeLimitEnabled: Bool?
    private var renderedChargeLimitPercent: Int?

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

        // 菜单栏：构建与勾选态在 MenuBarController，动作经 MenuBarDelegate 回到这里。
        menuController = MenuBarController(settings: settings, delegate: self)
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

        // 语言变化：菜单栏与三个窗口标题是命令式 API（不会随 SwiftUI 自动重绘），必须显式
        // 刷新；挂件视图树的文案在构造时取，也要重建（renderScale 置空即触发下面的重建分支）。
        if renderedLanguage != LocalizationManager.shared.language {
            renderedLanguage = LocalizationManager.shared.language
            menuController.rebuild()
            renderedChargeLimitEnabled = nil   // 菜单已整体重建，缓存失效
            renderedChargeLimitPercent = nil
            settingsWindowController?.refreshLocalizedText()
            chartController?.refreshLocalizedText()
            healthPanelController?.refreshLocalizedText()
            renderedScale = nil
        }

        // 充电上限改了 → 菜单标题里的百分比要跟着变（该项的标题与勾选态都是设定值的投影）。
        if renderedChargeLimitEnabled != settings.chargeLimitEnabled
            || renderedChargeLimitPercent != settings.chargeLimitPercent {
            renderedChargeLimitEnabled = settings.chargeLimitEnabled
            renderedChargeLimitPercent = settings.chargeLimitPercent
            menuController.rebuild()
        }

        let preset = SizePreset(rawValue: settings.sizeRaw) ?? .medium
        let scale = CGFloat(preset.scale)
        let width = baseWidth * scale
        let height = baseHeight * scale

        // 仅在尺寸档位变化时重建整棵 HUD 视图树：拖动 TDP 滑块会高频触发 commit，
        // 而 TDP / 穿透开关都不参与 PowerHUDView 构造（参数只有 monitor + scale），
        // 原先每次 commit 都重建一棵树纯属浪费；PowerHUDView 自己持有 @ObservedObject
        // monitor，运行期数值更新由它驱动，与这里无关。
        if renderedScale != scale {
            renderedScale = scale
            let hosting = NSHostingView(rootView: PowerHUDView(monitor: monitor,
                                                              limiter: monitor.chargeLimiter,
                                                              scale: scale))
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
    /// 几何计算抽到 MacBatteryCore/PanelGeometry（纯 Double API，U-04 的回归护栏）；
    /// 本方法只负责「取屏幕 + CG 类型互转 + 处理无屏幕的回退」。
    private func computeOrigin(size: NSSize) -> NSPoint? {
        guard let screen = NSScreen.main else { return nil }
        let vis = screen.visibleFrame
        let preset = SizePreset(rawValue: settings.sizeRaw) ?? .medium
        let margin = CGFloat(PanelGeometry.margin(glowMargin: Double(glowMargin),
                                                  scale: preset.scale))

        if settings.hasCustom {
            return NSPoint(x: settings.customX, y: settings.customY)
        }
        let corner = Corner(rawValue: settings.cornerRaw) ?? .topRight
        let p = PanelGeometry.origin(corner: corner,
                                     frameX: Double(vis.minX),
                                     frameY: Double(vis.minY),
                                     frameW: Double(vis.width),
                                     frameH: Double(vis.height),
                                     width: Double(size.width),
                                     height: Double(size.height),
                                     margin: Double(margin))
        return NSPoint(x: p.x, y: p.y)
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

    // 菜单栏已拆到 MenuBarController（第四批），动作经 MenuBarDelegate 回到这里。
}

extension FloatingPanelController: MenuBarDelegate {

    func menuOpenSettings() {
        settingsWindowController = SettingsWindowController.makeIfNeeded(existing: settingsWindowController,
                                                                         store: settings,
                                                                         updater: updater,
                                                                         limiter: monitor.chargeLimiter)
        settingsWindowController?.showAndActivate()
    }

    func menuOpenChart() {
        chartController = PowerChartPanelController.makeIfNeeded(existing: chartController,
                                                                 logger: logger,
                                                                 healthLogger: healthLogger)
        chartController?.showWindow(nil)
        window?.orderFront(nil) // 保证挂件仍在菜单之上可见
        NSApp.activate(ignoringOtherApps: true)
    }

    func menuOpenHealthChart() {
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

    func menuChooseCorner(_ rawValue: Int) {
        settings.cornerRaw = rawValue
        settings.hasCustom = false
        settings.commit()
        menuController.rebuild()
    }

    func menuChooseSize(_ rawValue: Int) {
        settings.sizeRaw = rawValue
        settings.commit()
        menuController.rebuild()
    }

    func menuTogglePassthrough() {
        settings.passthrough.toggle()
        settings.commit()
        menuController.rebuild()
    }

    func menuToggleChargeLimit() {
        settings.chargeLimitEnabled.toggle()
        // commit() 会经 onChange → applySettings() 刷新菜单标题与勾选态；
        // 这里不再显式 rebuild()，避免同一轮重建两次菜单。
        settings.commit()
    }

    func menuCheckForUpdates() {
        updater.checkForUpdates(interactive: true)
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