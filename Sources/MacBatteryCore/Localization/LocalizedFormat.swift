import Foundation

/// 随语言变化的数字 / 日期格式化。
///
/// ⚠️ **性能约定**：`PowerHUDView` 每秒刷新、图表每帧绘制坐标轴刻度，
/// 因此**禁止**在视图 `body` 或绘制路径里新建 `NumberFormatter` / `DateFormatter`
/// （构造是微秒级，每帧数十次会明显掉帧）。这里统一按「区域 + 模板」缓存实例，
/// 语言切换后区域变化会自动重建缓存，无需外部调用失效方法。
///
/// ⚠️ **线程约定**：缓存实例的**使用**（`string(from:)`）假定发生在主线程 ——
/// 与本项目所有 UI/绘制路径一致。缓存字典本身有锁保护，且重建不会改动在用的实例。
public enum LocalizedFormat {

    private static let lock = NSLock()
    private static var cachedLocale: Locale?
    private static var numberFormatters: [Int: NumberFormatter] = [:]
    private static var dateFormatters: [String: DateFormatter] = [:]

    // MARK: - 数字

    /// 区域化数字文本，跟随当前语言（如 `58.2` / `58,2`）。
    public static func number(_ value: Double, decimals: Int) -> String {
        number(value, decimals: decimals, locale: L10n.shared.locale)
    }

    /// 指定区域的数字文本。`decimals` 同时作为最少与最多小数位（保持原有 `%.1f` 的语义）。
    public static func number(_ value: Double, decimals: Int, locale: Locale) -> String {
        let formatter = numberFormatter(decimals: decimals, locale: locale)
        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "%.\(max(0, decimals))f", value)
    }

    // MARK: - 日期

    /// 区域化日期文本，跟随当前语言。
    ///
    /// - Parameter template: Unicode 日期字段模板（如 `jm` / `jms` / `MMdj`）。
    ///   由系统按区域解析成实际格式，12/24 小时制与日期顺序都会自动适配。
    public static func date(_ date: Date, template: String) -> String {
        date(date, template: template, locale: L10n.shared.locale)
    }

    /// 指定区域的日期文本。
    public static func date(_ date: Date, template: String, locale: Locale) -> String {
        let formatter = dateFormatter(template: template, locale: locale)
        return formatter.string(from: date)
    }

    // MARK: - 缓存

    private static func numberFormatter(decimals: Int, locale: Locale) -> NumberFormatter {
        lock.lock()
        defer { lock.unlock() }
        resetCacheIfNeeded(locale)
        if let cached = numberFormatters[decimals] { return cached }

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = max(0, decimals)
        formatter.maximumFractionDigits = max(0, decimals)
        numberFormatters[decimals] = formatter
        return formatter
    }

    private static func dateFormatter(template: String, locale: Locale) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        resetCacheIfNeeded(locale)
        if let cached = dateFormatters[template] { return cached }

        let formatter = DateFormatter()
        formatter.locale = locale
        // 必须用模板解析：直接设 `dateFormat` 会写死 12/24 小时制与字段顺序，
        // 对其它区域是错的（原先三处硬编码 "HH:mm" / "MM-dd HH:mm" 即为此类问题）。
        formatter.setLocalizedDateFormatFromTemplate(template)
        dateFormatters[template] = formatter
        return formatter
    }

    /// 区域变化（应用内切换语言）时整体重建缓存。
    private static func resetCacheIfNeeded(_ locale: Locale) {
        guard cachedLocale != locale else { return }
        cachedLocale = locale
        numberFormatters.removeAll(keepingCapacity: true)
        dateFormatters.removeAll(keepingCapacity: true)
    }
}
