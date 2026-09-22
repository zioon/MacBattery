import AppKit
import MacBatteryCore

/// 菜单栏动作转发的目标（由 FloatingPanelController 实现）。
@MainActor
protocol MenuBarDelegate: AnyObject {
    func menuOpenSettings()
    func menuOpenChart()
    func menuOpenHealthChart()
    func menuChooseCorner(_ rawValue: Int)
    func menuChooseSize(_ rawValue: Int)
    func menuTogglePassthrough()
    func menuCheckForUpdates()
}

/// 菜单栏图标与其菜单（第四批：从 FloatingPanelController 拆出的单一职责组件）。
///
/// 只负责「菜单长什么样 + 勾选态」；动作经 delegate 回给控制器执行。
/// `rebuild()` 会整表重建菜单 —— 勾选态来自 settings，语义与拆分前一致。
@MainActor
final class MenuBarController: NSObject {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings: SettingsStore
    private weak var delegate: MenuBarDelegate?

    init(settings: SettingsStore, delegate: MenuBarDelegate) {
        self.settings = settings
        self.delegate = delegate
        super.init()
        rebuild()
    }

    /// 重建整个菜单（原先的 buildStatusItem / rebuildMenuCheckmarks）。
    func rebuild() {
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.circle.fill",
                                           accessibilityDescription: "MacBattery")

        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: L("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // 历史图表
        let chartItem = NSMenuItem(title: L("menu.history_chart"), action: #selector(openChart), keyEquivalent: "g")
        chartItem.target = self
        menu.addItem(chartItem)

        // 电池健康（独立窗口）
        let healthItem = NSMenuItem(title: L("menu.battery_health"), action: #selector(openHealthChart), keyEquivalent: "h")
        healthItem.target = self
        menu.addItem(healthItem)

        menu.addItem(.separator())

        // 位置子菜单
        let posItem = NSMenuItem()
        posItem.title = L("common.position")
        let posSub = NSMenu()
        for c in Corner.allCases {
            let it = NSMenuItem(title: L(c.localizationKey), action: #selector(chooseCorner(_:)), keyEquivalent: "")
            it.tag = c.rawValue
            it.target = self
            it.state = (!settings.hasCustom && settings.cornerRaw == c.rawValue) ? .on : .off
            posSub.addItem(it)
        }
        posItem.submenu = posSub
        menu.addItem(posItem)

        // 大小子菜单
        let sizeItem = NSMenuItem()
        sizeItem.title = L("common.size")
        let sizeSub = NSMenu()
        for p in SizePreset.allCases {
            let it = NSMenuItem(title: L(p.localizationKey), action: #selector(chooseSize(_:)), keyEquivalent: "")
            it.tag = p.rawValue
            it.target = self
            it.state = (settings.sizeRaw == p.rawValue) ? .on : .off
            sizeSub.addItem(it)
        }
        sizeItem.submenu = sizeSub
        menu.addItem(sizeItem)

        // 鼠标穿透开关
        let passthroughItem = NSMenuItem(title: L("menu.passthrough"), action: #selector(togglePassthrough(_:)), keyEquivalent: "")
        passthroughItem.target = self
        passthroughItem.state = settings.passthrough ? .on : .off
        menu.addItem(passthroughItem)

        menu.addItem(.separator())
        let updateItem = NSMenuItem(title: L("menu.check_updates"), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func openSettings() { delegate?.menuOpenSettings() }
    @objc private func openChart() { delegate?.menuOpenChart() }
    @objc private func openHealthChart() { delegate?.menuOpenHealthChart() }
    @objc private func chooseCorner(_ sender: NSMenuItem) { delegate?.menuChooseCorner(sender.tag) }
    @objc private func chooseSize(_ sender: NSMenuItem) { delegate?.menuChooseSize(sender.tag) }
    @objc private func togglePassthrough(_ sender: NSMenuItem) { delegate?.menuTogglePassthrough() }
    @objc private func checkForUpdates() { delegate?.menuCheckForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
}
