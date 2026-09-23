import Foundation
import AppKit
import MacBatteryCore

// Corner / SizePreset 已抽到 MacBatteryCore/PanelGeometry.swift（纯几何 + 可独立单测）。

/// 应用设置：UserDefaults 持久化，UI 改动后调用 commit() 触发外部应用。
@MainActor
final class SettingsStore: ObservableObject {
    @Published var sizeRaw: Int
    @Published var cornerRaw: Int
    @Published var tdpWatts: Double
    @Published var passthrough: Bool
    @Published var hasCustom: Bool
    @Published var customX: Double
    @Published var customY: Double
    /// 界面语言（`.system` = 跟随系统）。
    @Published var language: AppLanguage
    /// 充电上限总开关。**默认关闭**：本功能会真的去写 SMC 断充电，必须由用户显式开启。
    @Published var chargeLimitEnabled: Bool
    /// 充电上限（%）。100 视为「不限制」，与关闭等价（见 `ChargeLimitPolicy`）。
    @Published var chargeLimitPercent: Int

    /// 设置变更后的回调（由 FloatingPanelController 注入，用于应用界面）。
    var onChange: (@MainActor () -> Void)?

    private static let prefix = "MacBattery.Settings."

    init() {
        let d = UserDefaults.standard
        sizeRaw = d.integer(forKey: Self.key("size"))
        cornerRaw = d.integer(forKey: Self.key("corner"))
        tdpWatts = (d.object(forKey: Self.key("tdp")) as? Double) ?? 45
        passthrough = (d.object(forKey: Self.key("passthrough")) as? Bool) ?? true
        hasCustom = d.bool(forKey: Self.key("hasCustom"))
        customX = d.double(forKey: Self.key("cx"))
        customY = d.double(forKey: Self.key("cy"))
        // 首启（或旧版本升级）时无该键 → 跟随系统，由引擎按系统首选语言匹配。
        language = AppLanguage(rawValue: d.string(forKey: Self.key("language")) ?? "") ?? .system

        // 充电上限：无该键（首启 / 从旧版本升级）→ 关闭 + 默认 80%。
        // 用 object(forKey:) 而不是 integer(forKey:) 区分「键不存在」与「值就是 0」：
        // integer 对缺失键返回 0，会被 clamp 成 50，等于给老用户凭空设了个 50% 的上限。
        chargeLimitEnabled = (d.object(forKey: Self.key("chargeLimitEnabled")) as? Bool) ?? false
        chargeLimitPercent = ChargeLimitPolicy.clamp(
            (d.object(forKey: Self.key("chargeLimitPercent")) as? Int)
                ?? ChargeLimitPolicy.defaultPercent)

        if sizeRaw < 0 || sizeRaw >= SizePreset.allCases.count { sizeRaw = SizePreset.medium.rawValue }
        if cornerRaw < 0 || cornerRaw >= Corner.allCases.count { cornerRaw = Corner.topRight.rawValue }

        // 必须先于任何界面构造完成语言设置：菜单栏、设置窗口、挂件都在本对象之后创建，
        // 它们构造时就会调用 L() 取文案。
        LocalizationManager.shared.apply(language)
    }

    /// 写入 UserDefaults 并通知外部（面板）应用变更。
    func commit() {
        let d = UserDefaults.standard
        d.set(sizeRaw, forKey: Self.key("size"))
        d.set(cornerRaw, forKey: Self.key("corner"))
        d.set(tdpWatts, forKey: Self.key("tdp"))
        d.set(passthrough, forKey: Self.key("passthrough"))
        d.set(hasCustom, forKey: Self.key("hasCustom"))
        d.set(customX, forKey: Self.key("cx"))
        d.set(customY, forKey: Self.key("cy"))
        d.set(language.storageValue, forKey: Self.key("language"))
        d.set(chargeLimitEnabled, forKey: Self.key("chargeLimitEnabled"))
        d.set(chargeLimitPercent, forKey: Self.key("chargeLimitPercent"))
        // 语言切换即时生效：更新引擎（幂等，语言未变时不重读资源）。
        LocalizationManager.shared.apply(language)
        onChange?()
    }

    /// 拖拽过程中持续记录窗口原点（只写 UserDefaults，不触发 onChange，避免拖拽被打断）。
    /// ⚠️ 刻意**不调用** `commit()`：程序化定位（选四角 / 改尺寸）也会触发 `didMove`，
    /// 若这里再触发 re-layout 会造成 U-04 修过的「位置预设被改写成自定义位置」回潮。
    /// （原先还有一个会 `commit()` 的 `saveCustomPosition(x:y:)`，因全仓无调用点且
    /// 一旦被接到 `didMove` 观察者上就会重新引入该缺陷，已删除。）
    func rememberDrag(x: Double, y: Double) {
        customX = x
        customY = y
        hasCustom = true
        let d = UserDefaults.standard
        d.set(x, forKey: Self.key("cx"))
        d.set(y, forKey: Self.key("cy"))
        d.set(hasCustom, forKey: Self.key("hasCustom"))
    }

    private static func key(_ k: String) -> String { prefix + k }
}