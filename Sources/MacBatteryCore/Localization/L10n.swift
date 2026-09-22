import Foundation

/// 用于定位「本模块所在的 bundle」的空类。
///
/// SwiftPM 生成的 `Bundle.module` 访问器正是靠 `Bundle(for: BundleFinder.self).resourceURL`
/// 找到资源 bundle 的 —— 这是 `swift test` 场景下**唯一**有效的一路：此时进程是 Xcode 里的
/// `xctest` 工具，`Bundle.main` 指向 `/Applications/Xcode.app/Contents/Developer/usr`，
/// 资源 bundle 却随 `.xctest` 一起放在它的 `Contents/Resources` 下。
/// 我们复制这一路（但不碰会 `fatalError` 的 `Bundle.module`）。
private final class ResourceBundleFinder {}

/// 多语言引擎。
///
/// 三条设计要点：
/// 1. **三级回退**：选中语言 → 默认语言（`AppLanguage.fallback`）→ 键名本身。
///    任何一环缺失都不会崩溃、也不会渲染出空白（最坏是界面显示键名，一眼可看出漏翻译）。
/// 2. **读表一次、查表常数级**：语言变化时把 `.lproj/Localizable.strings` 一次性读成字典，
///    之后每次取文案都是字典命中 —— 无 Bundle 查询、无磁盘 IO。这对挂件（每秒刷新）
///    与图表（每帧绘制刻度）是硬要求。
/// 3. **不写 `AppleLanguages`**：语言由进程内自行决定，切换无需重启、不改系统偏好设置。
public final class L10n {

    public static let shared = L10n()

    private let lock = NSLock()

    /// 用户在设置里选的语言（可能仍是 `.system`）。
    private var selection: AppLanguage = .fallback
    /// 实际加载的语言（`.system` 已被解析成具体语言）。
    private var current: AppLanguage = .fallback
    private var loadedOnce = false

    private var currentTable = LocalizationTable.empty(.fallback)
    private var fallbackTable = LocalizationTable.empty(.fallback)
    /// 字典读取失败时的兜底 bundle（逐键 `localizedString`）。
    private var currentBundle: Bundle?
    private var fallbackBundle: Bundle?

    private var missingKeys: Set<String> = []

    /// 系统首选语言的注入点：默认取 `Locale.preferredLanguages`，测试可替换。
    public var preferredLanguagesProvider: () -> [String] = { Locale.preferredLanguages }

    public init() {}

    /// 仅供测试：用内存表构造引擎，完全不读 Bundle，故可在任何环境下断言回退链行为。
    init(currentTable: LocalizationTable,
         fallbackTable: LocalizationTable,
         language: AppLanguage) {
        self.currentTable = currentTable
        self.fallbackTable = fallbackTable
        self.current = language
        self.selection = language
        self.loadedOnce = true
    }

    // MARK: - 状态

    /// 实际加载的语言（一定是具体语言）。
    public var language: AppLanguage {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// 用户在设置里选的语言。
    public var selectedLanguage: AppLanguage {
        lock.lock(); defer { lock.unlock() }
        return selection
    }

    /// 当前语言对应的区域（数字 / 日期格式化使用）。
    public var locale: Locale { Locale(identifier: language.localeIdentifier) }

    /// 取过但所有表都没有的键（测试断言用；DEBUG 下首次缺失会打印一行提示）。
    public var missing: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return missingKeys
    }

    // MARK: - 语言设置

    /// 应用语言设置：启动读完设置后调用一次，此后每次设置变更再调用。
    ///
    /// 幂等且廉价：解析结果与当前一致时不重读资源（`SettingsStore.commit()` 会被
    /// TDP 滑块拖动高频触发，不能每次都读盘）。
    public func setLanguage(_ language: AppLanguage) {
        let resolved = LanguageResolver.resolve(preferredLanguages: preferredLanguagesProvider(),
                                                selected: language)
        lock.lock()
        let needsReload = !loadedOnce || resolved != current
        selection = language
        current = resolved
        loadedOnce = true
        lock.unlock()

        guard needsReload else { return }
        loadTables()
    }

    private func loadTables() {
        let target = language
        let targetTable = Self.loadTable(for: target)
        // 目标语言就是默认语言时，两张表是同一份，避免重复读盘。
        let (fallbackT, fallbackB) = target == AppLanguage.fallback
            ? (targetTable, Self.bundle(for: target))
            : (Self.loadTable(for: AppLanguage.fallback), Self.bundle(for: AppLanguage.fallback))

        lock.lock()
        currentTable = targetTable
        currentBundle = Self.bundle(for: target)
        fallbackTable = fallbackT
        fallbackBundle = fallbackB
        lock.unlock()
    }

    // MARK: - 取文案

    /// 取一条文案（不含格式化参数）。
    public func text(_ key: String) -> String { text(key, []) }

    /// 取一条文案并按当前区域格式化 `args`。
    ///
    /// - Note: `args` 为空时**不做** `String(format:)` —— 文案里可以安全地出现字面 `%`
    ///   （如「左轴：%」），不必写成 `%%`。
    public func text(_ key: String, _ args: [CVarArg]) -> String {
        guard let format = format(for: [key]) else {
            record(missing: key)
            return key
        }
        return apply(format, args)
    }

    /// 取一条带复数变化的文案。
    ///
    /// 查键顺序：本类别（`<key>.one` / `<key>.other`，先在当前语言表、再在默认语言表）
    /// → 通用 `<key>.other` → 键名本身。`count` 恒为第一个格式参数。
    public func plural(_ key: String, count: Int, _ args: [CVarArg]) -> String {
        let category = PluralCategory.select(count: count, language: language)
        let candidates = ["\(key).\(category.rawValue)", "\(key).other"]
        guard let format = format(for: candidates) else {
            record(missing: key)
            return key
        }
        return apply(format, [count] + args)
    }

    // MARK: - 内部实现

    /// 按候选键依次在「当前语言表 → 默认语言表」中查一条格式串。
    private func format(for candidateKeys: [String]) -> String? {
        lock.lock()
        let currentT = currentTable
        let fallbackT = fallbackTable
        let currentB = currentBundle
        let fallbackB = fallbackBundle
        lock.unlock()

        for key in candidateKeys {
            if let value = lookup(key, in: currentT, bundle: currentB) { return value }
        }
        for key in candidateKeys {
            if let value = lookup(key, in: fallbackT, bundle: fallbackB) { return value }
        }
        return nil
    }

    /// 单键查表：先查已加载的字典，再退回 bundle 逐键查询。
    ///
    /// 两条路径都保留的原因：字典读取更快且能枚举键名（一致性测试需要），
    /// 但万一 `.strings` 形态异常导致解析失败，逐键 `localizedString` 仍能取到文案。
    private func lookup(_ key: String, in table: LocalizationTable, bundle: Bundle?) -> String? {
        if let value = table.value(for: key) { return value }
        guard let bundle else { return nil }
        let value = bundle.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? nil : value
    }

    private func apply(_ format: String, _ args: [CVarArg]) -> String {
        guard !args.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: args)
    }

    private func record(missing key: String) {
        lock.lock()
        let isNew = missingKeys.insert(key).inserted
        lock.unlock()
        #if DEBUG
        // 调试日志不本地化（面向排查），否则同一条缺失在不同语言下文本不同、无法检索。
        if isNew { print("[i18n] missing string key: \(key)") }
        #endif
    }

    // MARK: - 资源定位

    /// 读取某语言的资源表。
    ///
    /// 主路径：`<lang>.lproj/Localizable.strings` 直接读成字典（快、可枚举键名）。
    /// 取不到时返回空表，由三级回退落到键名 —— 绝不 `fatalError`：
    /// 即使打包漏了资源，界面最坏显示键名，也不会让应用起不来。
    static func loadTable(for language: AppLanguage) -> LocalizationTable {
        guard let bundle = bundle(for: language),
              let path = bundle.path(forResource: "Localizable", ofType: "strings"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String],
              !dict.isEmpty else {
            return .empty(language)
        }
        return LocalizationTable(language: language, entries: dict)
    }

    /// 定位某语言的 `.lproj`。
    ///
    /// ⚠️ **刻意不使用 `Bundle.module`**：SwiftPM 生成的访问器在找不到资源 bundle 时走的是
    /// `fatalError`（表现为 `_assertionFailure` → SIGILL）。v1.2.0 正是把它放在候选列表里，
    /// 于是在 `applicationDidFinishLaunching` 阶段直接崩掉 —— 崩溃栈就是
    /// `closure #1 in variable initialization expression of static NSBundle.module`。
    /// 这里改成**纯查询式**搜索：任何一环缺失都只返回 nil，由三级回退兜住（界面显示键名），
    /// 绝不让「找不到翻译」升级成「应用起不来」。
    static func bundle(for language: AppLanguage) -> Bundle? {
        for host in resourceHosts() {
            let url = host.appendingPathComponent("\(language.rawValue).lproj")
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let bundle = Bundle(url: url) else { continue }
            return bundle
        }
        return nil
    }

    /// 可能存放 `.lproj` 的目录，按优先级排列。
    ///
    /// 三种运行形态的资源位置都不同，这里逐个覆盖（都不依赖会 `fatalError` 的 `Bundle.module`）：
    /// - **`.app`**：`Contents/Resources/<lang>.lproj`（主路径，CI 会直接放这里）；
    /// - **裸二进制 `swift run`**：资源 bundle 与可执行文件同在 `.build/<triple>/<config>/`，
    ///   即 `Bundle.main.bundleURL`；
    /// - **`swift test`**：**实测**（CI 里打印出来的）`Bundle.main` 指向的是 Xcode 自带的
    ///   `xctest` 工具（`/Applications/Xcode*.app/Contents/Developer/usr[/bin]`），资源 bundle
    ///   根本不在 `Bundle.main` 一侧；真正有效的一路是 `Bundle(for: ResourceBundleFinder.self)`
    ///   —— 也就是 `.xctest` bundle 及其 `Contents/Resources`。`PACKAGE_RESOURCE_BUNDLE_PATH`
    ///   在本机 CI 上**未被设置**，保留它只是兜底。
    ///
    /// 每个目录下再按「名字以 `MacBatteryCore.bundle` 结尾」通配一层 —— 这样就不必猜
    /// SwiftPM 用的是包名（`MacBattery_`）还是小写的包标识（`macbattery_`）。
    private static func resourceHosts() -> [URL] {
        var hosts: [URL] = []

        // ① .app：Contents/Resources（CI 会把 .lproj 直接放这里）。
        if let resources = Bundle.main.resourceURL { hosts.append(resources) }
        // ② 裸二进制 swift run：可执行文件所在目录。
        hosts.append(Bundle.main.bundleURL)
        hosts.append(Bundle.main.bundleURL.deletingLastPathComponent())

        // ③ 本模块所在的 bundle —— swift test 场景唯一有效的一路（见 ResourceBundleFinder 说明）。
        let moduleBundle = Bundle(for: ResourceBundleFinder.self)
        if let resources = moduleBundle.resourceURL { hosts.append(resources) }
        hosts.append(moduleBundle.bundleURL)
        hosts.append(moduleBundle.bundleURL.deletingLastPathComponent())

        // ④ SwiftPM 在 DEBUG 下会用它指出资源 bundle 的位置（生成的访问器也读这个变量）。
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"] {
            let url = URL(fileURLWithPath: override)
            hosts.append(url)
            hosts.append(url.deletingLastPathComponent())
        }

        // ⑤ 每个目录下再接受「名字以 MacBatteryCore.bundle 结尾」的条目 ——
        //    这样不必猜 SwiftPM 用的是包名（MacBattery_）还是小写的包标识（macbattery_）。
        let bases = hosts
        for base in bases {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
            for entry in entries where entry.hasSuffix("MacBatteryCore.bundle") {
                hosts.append(base.appendingPathComponent(entry))
            }
        }

        var seen = Set<String>()
        return hosts.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// 仅供诊断：把搜索过的目录、以及其中与本地化相关的条目列成一行。
    ///
    /// 资源加载失败时（打包布局变化、新平台入口等）把它放进断言消息里，
    /// 下一次失败就能直接看出「该在哪儿、实际有什么」，不用再猜一轮 CI。
    static func resourceHostsForDiagnostics() -> String {
        var lines: [String] = []
        for host in resourceHosts() {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: host.path)) ?? []
            let relevant = entries
                .filter { $0.hasSuffix(".lproj") || $0.hasSuffix(".bundle") }
                .sorted()
            let flag = FileManager.default.fileExists(atPath: host.path) ? "" : " (missing)"
            lines.append("\(host.path)\(flag) -> [\(relevant.joined(separator: ", "))]")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 调用点 API

/// 取一条本地化文案（三级回退，永不返回空串）。
///
/// ⚠️ SwiftUI 调用点必须写成 `Text(L("..."))`：`L()` 返回 `String`，`Text(String)`
/// 按字面渲染；若直接写 `Text("中文")`，字面量会走 `LocalizedStringKey` →
/// `Bundle.main` + `AppleLanguages`，**绕过这里的语言选择**，导致切语言后该处文案不变。
/// 这一条由 CI 的 `Scripts/check_hardcoded_strings.py` 强制（残留 CJK 字面量即报错）。
public func L(_ key: String, _ args: CVarArg...) -> String {
    L10n.shared.text(key, args)
}

/// 取一条带复数变化的本地化文案（按当前语言的复数类别选 `<key>.one` / `<key>.other`）。
public func LP(_ key: String, count: Int, _ args: CVarArg...) -> String {
    L10n.shared.plural(key, count: count, args)
}
