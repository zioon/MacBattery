import XCTest
@testable import MacBatteryCore

/// 多语言引擎的回归护栏。
///
/// 本机没有 Swift 工具链，CI 的 `swift test` 是唯一编译与验证通道，因此这里覆盖的是
/// **无法靠肉眼在界面上验证**的部分：三级回退、系统语言匹配、复数类别、区域化格式，
/// 以及两份资源文件的键名 / 占位符一致性（漏翻译、占位符漂移都直接红灯）。
final class LocalizationTests: XCTestCase {

    override func tearDown() {
        // L10n.shared 是进程级单例，用例改过它之后必须还原，保证用例顺序无关。
        L10n.shared.preferredLanguagesProvider = { Locale.preferredLanguages }
        L10n.shared.setLanguage(.zhHans)
        super.tearDown()
    }

    // MARK: - 默认语言与系统语言匹配

    func testDefaultLanguageIsSimplifiedChinese() {
        XCTAssertEqual(AppLanguage.fallback, .zhHans)
        XCTAssertFalse(AppLanguage.supported.contains(.system), "system 不是可加载的资源语言")
        XCTAssertEqual(AppLanguage.supported, [.zhHans, .en])
    }

    func testNormalizeSystemIdentifiers() {
        XCTAssertEqual(LanguageResolver.normalize("zh-Hans-CN"), .zhHans)
        XCTAssertEqual(LanguageResolver.normalize("zh-CN"), .zhHans)
        XCTAssertEqual(LanguageResolver.normalize("zh-SG"), .zhHans)
        XCTAssertEqual(LanguageResolver.normalize("en"), .en)
        XCTAssertEqual(LanguageResolver.normalize("en-GB"), .en)
        // 首批不含繁体与其它语言 → 不匹配，交由默认语言回退处理
        XCTAssertNil(LanguageResolver.normalize("zh-TW"))
        XCTAssertNil(LanguageResolver.normalize("zh-Hant-TW"))
        XCTAssertNil(LanguageResolver.normalize("zh-HK"))
        XCTAssertNil(LanguageResolver.normalize("ja-JP"))
    }

    func testResolveFollowsSystemThenFallsBackToDefault() {
        XCTAssertEqual(LanguageResolver.resolve(preferredLanguages: ["en-US", "zh-Hans-CN"],
                                                selected: .system), .en)
        XCTAssertEqual(LanguageResolver.resolve(preferredLanguages: ["zh-Hans-CN", "en-US"],
                                                selected: .system), .zhHans)
        // 首选语言不支持时继续往后找
        XCTAssertEqual(LanguageResolver.resolve(preferredLanguages: ["ja-JP", "en-GB"],
                                                selected: .system), .en)
        // 全部不支持 → 默认语言
        XCTAssertEqual(LanguageResolver.resolve(preferredLanguages: ["ja-JP", "ar-EG"],
                                                selected: .system), .zhHans)
        XCTAssertEqual(LanguageResolver.resolve(preferredLanguages: [], selected: .system), .zhHans)
        // 用户显式选定的语言优先于系统语言
        XCTAssertEqual(LanguageResolver.resolve(preferredLanguages: ["en-US"],
                                                selected: .zhHans), .zhHans)
    }

    // MARK: - 三级回退

    func testSelectedLanguageHasPriority() {
        let engine = makeEngine(current: ["a": "English A"], fallback: ["a": "中文 A"])
        XCTAssertEqual(engine.text("a"), "English A")
    }

    func testFallsBackToDefaultLanguage() {
        let engine = makeEngine(current: [:], fallback: ["b": "中文 B"])
        XCTAssertEqual(engine.text("b"), "中文 B", "翻译缺失必须回退到默认语言，而不是留空")
    }

    func testMissingKeyFallsBackToKeyItself() {
        let engine = makeEngine(current: [:], fallback: [:])
        XCTAssertEqual(engine.text("nope.key"), "nope.key")
        XCTAssertEqual(engine.missing, ["nope.key"], "缺失键应被记录，便于排查")
    }

    func testArgumentsAreAppliedWithCurrentLocale() {
        let engine = makeEngine(current: ["v": "%d W"], fallback: [:])
        XCTAssertEqual(engine.text("v", [58]), "58 W")
    }

    func testLiteralPercentIsSafeWithoutArguments() {
        // 不含参数的文案里可以出现字面 %（如「左轴：%」），不需要写成 %% —— 
        // L() 在 args 为空时不做 String(format:)，因此不会被当成格式串解析。
        let engine = makeEngine(current: ["hint": "Left: %  ·  Right: W"], fallback: [:])
        XCTAssertEqual(engine.text("hint"), "Left: %  ·  Right: W")
    }

    // MARK: - 复数

    func testPluralCategoryFollowsLanguage() {
        let english = ["n.one": "%d sample", "n.other": "%d samples"]
        let en = makeEngine(current: english, fallback: [:], language: .en)
        XCTAssertEqual(en.plural("n", count: 0, []), "0 samples")
        XCTAssertEqual(en.plural("n", count: 1, []), "1 sample")
        XCTAssertEqual(en.plural("n", count: 2, []), "2 samples")

        // 中文没有复数变化：任何数量都走 .other
        let zh = makeEngine(current: ["n.other": "样本 %d 个"], fallback: [:], language: .zhHans)
        XCTAssertEqual(zh.plural("n", count: 1, []), "样本 1 个")
        XCTAssertEqual(zh.plural("n", count: 5, []), "样本 5 个")
    }

    func testPluralFallsBackToOtherCategory() {
        // 当前语言只有 .other（如英文漏了单数形）→ 用 .other 兜底，不露键名
        let engine = makeEngine(current: ["n.other": "%d items"], fallback: [:], language: .en)
        XCTAssertEqual(engine.plural("n", count: 1, []), "1 items")
    }

    func testPluralFallsBackToDefaultLanguage() {
        let engine = makeEngine(current: [:], fallback: ["n.other": "样本 %d 个"], language: .en)
        XCTAssertEqual(engine.plural("n", count: 3, []), "样本 3 个")
    }

    // MARK: - 区域化格式化

    func testNumberFollowsLocale() {
        XCTAssertEqual(LocalizedFormat.number(58.2, decimals: 1, locale: Locale(identifier: "en_US")), "58.2")
        XCTAssertEqual(LocalizedFormat.number(58.2, decimals: 1, locale: Locale(identifier: "zh_CN")), "58.2")
        // 德语用逗号作小数分隔符 —— 原先写死的 String(format: "%.1f") 在德语区域是错的
        XCTAssertEqual(LocalizedFormat.number(58.2, decimals: 1, locale: Locale(identifier: "de_DE")), "58,2")
    }

    func testNumberDecimalsAreRespected() {
        XCTAssertEqual(LocalizedFormat.number(58.24, decimals: 0, locale: Locale(identifier: "en_US")), "58")
        XCTAssertEqual(LocalizedFormat.number(4.0, decimals: 1, locale: Locale(identifier: "en_US")), "4.0")
    }

    func testDateUsesLocalizedTemplateNotHardcodedFormat() {
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let en = LocalizedFormat.date(date, template: "jm", locale: Locale(identifier: "en_US"))
        let zh = LocalizedFormat.date(date, template: "jm", locale: Locale(identifier: "zh_CN"))
        // 12/24 小时制由区域决定：写死 "HH:mm" 的话英文区域永远拿不到 AM/PM
        XCTAssertTrue(en.contains("AM") || en.contains("PM"), "en_US 的 jm 应为 12 小时制，实际：\(en)")
        XCTAssertFalse(zh.contains("AM") || zh.contains("PM"), "zh_CN 的 jm 应为 24 小时制，实际：\(zh)")
    }

    func testLocaleIdentifierPerLanguage() {
        XCTAssertEqual(AppLanguage.zhHans.localeIdentifier, "zh_CN")
        XCTAssertEqual(AppLanguage.en.localeIdentifier, "en_US")
    }

    // MARK: - 资源文件一致性（漏翻译 / 占位符漂移的关卡）

    func testBothLanguageTablesAreLoaded() {
        for language in AppLanguage.supported {
            let table = L10n.loadTable(for: language)
            XCTAssertFalse(table.entries.isEmpty,
                           """
                           \(language.rawValue) 资源未加载 —— 检查 Package.swift 的 resources 声明与 .lproj 目录布局。
                           已搜索的目录（含其中的 .lproj / .bundle）：
                           \(L10n.resourceHostsForDiagnostics())
                           """)
        }
    }

    func testAllLanguagesShareTheSameKeys() {
        let zh = L10n.loadTable(for: .zhHans)
        let en = L10n.loadTable(for: .en)

        let missingInEnglish = zh.keys.subtracting(en.keys).sorted()
        XCTAssertTrue(missingInEnglish.isEmpty,
                      "en 缺少这些键（请补齐，否则运行时回退中文）：\(missingInEnglish)")

        // en 允许多出「复数单数形」(.one)：中文没有复数变化，只写 .other。
        let allowedExtras: Set<String> = Set(zh.keys.compactMap { key -> String? in
            guard key.hasSuffix(".other") else { return nil }
            return String(key.dropLast(".other".count)) + ".one"
        })
        let unexpected = en.keys.subtracting(zh.keys).subtracting(allowedExtras).sorted()
        XCTAssertTrue(unexpected.isEmpty, "en 里有多余的键（键名拼写不一致？）：\(unexpected)")
    }

    func testFormatSpecifiersMatchAcrossLanguages() {
        let zh = L10n.loadTable(for: .zhHans)
        let en = L10n.loadTable(for: .en)
        for (key, zhValue) in zh.entries {
            guard let enValue = en.entries[key] else { continue }
            XCTAssertEqual(specifiers(in: zhValue), specifiers(in: enValue),
                           "键 \(key) 的格式占位符与默认语言不一致：「\(zhValue)」vs「\(enValue)」")
        }
    }

    func testPluralKeysExistInDefaultLanguage() {
        let zh = L10n.loadTable(for: .zhHans)
        let bases = ["chart.summary.samples", "health.unit.cycles",
                     "duration.seconds", "duration.minutes"]
        for base in bases {
            XCTAssertNotNil(zh.entries["\(base).other"], "缺少复数键 \(base).other")
        }
    }

    func testNoEmptyValuesInResources() {
        for language in AppLanguage.supported {
            let table = L10n.loadTable(for: language)
            let empty = table.entries
                .filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .keys.sorted()
            XCTAssertTrue(empty.isEmpty, "\(language.rawValue) 存在空值键：\(empty)")
        }
    }

    // MARK: - 端到端（真读 Bundle）

    func testSharedEngineReadsBundledResources() {
        L10n.shared.preferredLanguagesProvider = { [] }

        L10n.shared.setLanguage(.system)
        XCTAssertEqual(L10n.shared.language, .zhHans, "系统语言不支持时应落到默认语言")
        XCTAssertEqual(L("menu.quit"), "退出 MacBattery")

        L10n.shared.setLanguage(.en)
        XCTAssertEqual(L("menu.quit"), "Quit MacBattery")
        XCTAssertEqual(L("common.cancel"), "Cancel")
    }

    func testLanguageMenuLabelsUseAutonyms() {
        L10n.shared.preferredLanguagesProvider = { [] }

        L10n.shared.setLanguage(.zhHans)
        XCTAssertEqual(AppLanguage.zhHans.menuLabel, "简体中文")
        XCTAssertEqual(AppLanguage.en.menuLabel, "English")
        XCTAssertEqual(AppLanguage.system.menuLabel, "跟随系统")

        // 语言自名不随界面语言变化：切到英文后「简体中文」仍是「简体中文」
        L10n.shared.setLanguage(.en)
        XCTAssertEqual(AppLanguage.zhHans.menuLabel, "简体中文")
        XCTAssertEqual(AppLanguage.en.menuLabel, "English")
        XCTAssertEqual(AppLanguage.system.menuLabel, "System")
    }

    func testSwitchingLanguageTwiceKeepsTablesConsistent() {
        L10n.shared.preferredLanguagesProvider = { [] }
        L10n.shared.setLanguage(.en)
        L10n.shared.setLanguage(.zhHans)
        XCTAssertEqual(L("menu.quit"), "退出 MacBattery")
        L10n.shared.setLanguage(.en)
        XCTAssertEqual(L("menu.quit"), "Quit MacBattery")
    }

    // MARK: - 辅助

    private func makeEngine(current: [String: String],
                            fallback: [String: String],
                            language: AppLanguage = .en) -> L10n {
        L10n(currentTable: LocalizationTable(language: language, entries: current),
             fallbackTable: LocalizationTable(language: AppLanguage.fallback, entries: fallback),
             language: language)
    }

    /// 提取格式串里的类型说明符（排序后比较，忽略 `%%` 这个转义后的字面百分号）。
    private func specifiers(in format: String) -> [String] {
        let pattern = "%(?:\\d+\\$)?[-+ #0]*\\d*(?:\\.\\d+)?[a-zA-Z@]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(format.startIndex..<format.endIndex, in: format)
        return regex.matches(in: format, range: range).compactMap { match in
            guard let matched = Range(match.range, in: format) else { return nil }
            return String(format[matched])
        }.sorted()
    }
}
