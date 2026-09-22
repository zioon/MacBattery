import Foundation

/// CLDR 复数类别。
///
/// 本项目只支持中文与英文，二者仅需 `one` / `other` 两类。
///
/// **为什么不用 `.stringsdict`**：Foundation 未公开 CLDR 复数规则 API（无法自己判定类别），
/// 而 `.stringsdict` 的解析挂在 bundle 的内部行为上 —— 本项目没有本地 Swift 工具链、
/// CI 是唯一编译通道，那种「解析失败时界面直接显示 `%#@count@` 乱码」的失败模式无法在
/// 本地验证。因此改为**自己按语言判定类别**，复数形式放在资源文件里以
/// `<key>.one` / `<key>.other` 为键：行为完全可单测，且将来新增语言若需要
/// `few` / `many`，只需补键并扩展 `select` 的分支。
public enum PluralCategory: String {
    case one
    case other

    /// 判定某语言下 `count` 所属的复数类别。
    public static func select(count: Int, language: AppLanguage) -> PluralCategory {
        switch language {
        case .en:
            // 英语：仅 1 用单数（0 与 2+ 都用复数）。
            return count == 1 ? .one : .other
        case .zhHans, .system:
            // 中文没有复数变化，恒用 other。
            return .other
        }
    }
}

/// 一份语言资源表的纯数据形式（与 Bundle 无关，便于单测）。
public struct LocalizationTable: Equatable {

    public let language: AppLanguage
    public let entries: [String: String]

    public init(language: AppLanguage, entries: [String: String]) {
        self.language = language
        self.entries = entries
    }

    public static func empty(_ language: AppLanguage) -> LocalizationTable {
        LocalizationTable(language: language, entries: [:])
    }

    /// 全部键名（供「各语言键名保持一致」的一致性测试使用）。
    public var keys: Set<String> { Set(entries.keys) }

    /// 取一条文案；未命中返回 `nil`（回退由 `L10n` 统一负责）。
    public func value(for key: String) -> String? { entries[key] }

    /// 取复数形式对应的键：优先本类别 `<key>.<category>`，其次通用 `<key>.other`。
    public func pluralKey(for key: String, category: PluralCategory) -> String? {
        let exact = "\(key).\(category.rawValue)"
        if entries[exact] != nil { return exact }
        let other = "\(key).other"
        return entries[other] != nil ? other : nil
    }
}
