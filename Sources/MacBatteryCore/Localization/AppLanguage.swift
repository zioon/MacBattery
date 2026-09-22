import Foundation

/// 应用界面语言。
///
/// `rawValue` 即资源目录名（`<rawValue>.lproj`），`.system` 是唯一的非具体语言取值。
public enum AppLanguage: String, CaseIterable {

    /// 跟随系统：启动时按系统首选语言匹配，匹配不到则用 `fallback`。
    case system
    case zhHans = "zh-Hans"
    case en = "en"

    /// 默认语言，同时也是翻译缺失时的回退目标。
    ///
    /// 刻意取简体中文而非英文：本应用此前的界面文案全部是中文，以中文为默认语言
    /// 可保证既有用户升级后所见内容与升级前**逐字一致**，这是「不破坏现有功能」的底线。
    public static let fallback: AppLanguage = .zhHans

    /// 已提供资源文件的语言（不含 `.system` —— 它不是一个可加载的资源目录）。
    public static let supported: [AppLanguage] = [.zhHans, .en]

    /// UserDefaults 持久化用的值。
    public var storageValue: String { rawValue }

    /// 语言选择器里的显示名。
    ///
    /// 具体语言一律用**自名**（简体中文 / English 在任何语言下都是原文，符合 Apple
    /// 语言列表惯例），因此这三个值在各语言资源文件里是相同的、**不要翻译**。
    public var menuLabel: String { L("language.\(rawValue)") }

    /// 该语言对应的区域标识，供数字 / 日期格式化使用。
    ///
    /// 说明：应用内切换语言后，数字与日期的区域也跟随应用语言（而非系统区域），
    /// 避免出现「英文文案 + 系统区域数字格式」的混搭。
    public var localeIdentifier: String {
        switch self {
        case .zhHans: return "zh_CN"
        case .en: return "en_US"
        case .system: return Locale.current.identifier
        }
    }
}

/// 系统语言标识 → 支持语言 的归一化与匹配。
public enum LanguageResolver {

    /// 把一个系统语言标识归一化到已支持的语言；不支持则返回 `nil`。
    ///
    /// - `zh-Hans-CN` / `zh-CN` / `zh-SG` → `.zhHans`
    /// - `zh-Hant-TW` / `zh-TW` / `zh-HK` / `zh-MO` → `nil`（首批不含繁体，由调用方回退默认语言）
    /// - `en` / `en-US` / `en-GB` → `.en`
    /// - 其它（`ja-JP` 等）→ `nil`
    public static func normalize(_ identifier: String) -> AppLanguage? {
        let lowered = identifier.lowercased()
        if lowered.hasPrefix("zh") {
            let isTraditional = lowered.contains("hant")
                || lowered.hasSuffix("tw")
                || lowered.hasSuffix("hk")
                || lowered.hasSuffix("mo")
            return isTraditional ? nil : .zhHans
        }
        if lowered.hasPrefix("en") { return .en }
        return nil
    }

    /// 解析出实际要加载的语言。
    ///
    /// - Parameters:
    ///   - preferredLanguages: 系统首选语言（按优先级排序）；生产环境传
    ///     `Locale.preferredLanguages`，测试可注入固定值。
    ///   - selected: 用户在设置里选的语言；`.system` 表示跟随系统。
    /// - Returns: 一定是一个**具体语言**（不会是 `.system`）；全部不匹配时返回 `AppLanguage.fallback`。
    public static func resolve(preferredLanguages: [String], selected: AppLanguage) -> AppLanguage {
        guard selected == .system else { return selected }
        for identifier in preferredLanguages {
            if let matched = normalize(identifier) { return matched }
        }
        return AppLanguage.fallback
    }
}
