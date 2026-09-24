import XCTest
@testable import MacBatteryCore

/// 充电上限的决策规则（含迟滞）与 App↔helper 协议。
///
/// 这层必须测得够细：本机没有 Swift 工具链，「充到 80% 到底会不会停」无法在本地试，
/// 唯一的机会就是在 CI 里把每个分支钉死。
final class ChargeLimitTests: XCTestCase {

    // MARK: - 参数（clamp）

    func testClampKeepsValuesInsideRange() {
        XCTAssertEqual(ChargeLimitPolicy.clamp(0), ChargeLimitPolicy.minimumPercent)
        XCTAssertEqual(ChargeLimitPolicy.clamp(-40), ChargeLimitPolicy.minimumPercent)
        XCTAssertEqual(ChargeLimitPolicy.clamp(999), ChargeLimitPolicy.maximumPercent)
        XCTAssertEqual(ChargeLimitPolicy.clamp(100), 100)
    }

    func testClampAlignsToStep() {
        // 57 → 最近的 5 的倍数（55）；83 → 85。
        XCTAssertEqual(ChargeLimitPolicy.clamp(57), 55)
        XCTAssertEqual(ChargeLimitPolicy.clamp(83), 85)
        // 越界值先夹取再对齐：37 已在 50 以下，结果是下界本身。
        XCTAssertEqual(ChargeLimitPolicy.clamp(37), ChargeLimitPolicy.minimumPercent)
        // 恰好落在步进点上时不能被挪动。
        for value in stride(from: ChargeLimitPolicy.minimumPercent,
                            through: ChargeLimitPolicy.maximumPercent,
                            by: ChargeLimitPolicy.stepPercent) {
            XCTAssertEqual(ChargeLimitPolicy.clamp(value), value)
        }
    }

    func testClampResultIsAlwaysASelectableStep() {
        for raw in -10...110 {
            let clamped = ChargeLimitPolicy.clamp(raw)
            XCTAssertGreaterThanOrEqual(clamped, ChargeLimitPolicy.minimumPercent, "raw=\(raw)")
            XCTAssertLessThanOrEqual(clamped, ChargeLimitPolicy.maximumPercent, "raw=\(raw)")
            XCTAssertEqual((clamped - ChargeLimitPolicy.minimumPercent)
                            % ChargeLimitPolicy.stepPercent, 0, "raw=\(raw)")
        }
    }

    func testDefaultPercentIsSelectable() {
        XCTAssertEqual(ChargeLimitPolicy.clamp(ChargeLimitPolicy.defaultPercent),
                       ChargeLimitPolicy.defaultPercent)
        XCTAssertEqual(ChargeLimitPolicy.defaultPercent, 80)
    }

    // MARK: - 触发条件

    func testDisabledNeverActs() {
        XCTAssertEqual(ChargeLimitPolicy.action(level: 100, limit: 80, enabled: false,
                                                onExternalPower: true, currentlyInhibited: false),
                       .noChange)
        // 已在抑制中再关掉开关，也不由决策层负责释放（释放由执行层显式补一次 allow）。
        XCTAssertEqual(ChargeLimitPolicy.action(level: 95, limit: 80, enabled: false,
                                                onExternalPower: true, currentlyInhibited: true),
                       .noChange)
    }

    func testLimitOfHundredMeansNoLimit() {
        // 100% 等价于关闭：不与系统自带的优化充电在一个永远到不了的阈值上互相拉扯。
        XCTAssertEqual(ChargeLimitPolicy.action(level: 100, limit: 100, enabled: true,
                                                onExternalPower: true, currentlyInhibited: false),
                       .noChange)
        XCTAssertFalse(ChargeLimitPolicy.isAtLimit(level: 100, limit: 100, enabled: true))
    }

    func testOnBatteryDoesNotAct() {
        XCTAssertEqual(ChargeLimitPolicy.action(level: 90, limit: 80, enabled: true,
                                                onExternalPower: false, currentlyInhibited: false),
                       .noChange)
        // 拔电时即便此前处于抑制中，也不下发指令（避免留下一条「禁止充电」的残留）。
        XCTAssertEqual(ChargeLimitPolicy.action(level: 90, limit: 80, enabled: true,
                                                onExternalPower: false, currentlyInhibited: true),
                       .noChange)
    }

    func testInhibitsExactlyAtAndAboveLimit() {
        for level in [80, 81, 99, 100] {
            XCTAssertEqual(ChargeLimitPolicy.action(level: level, limit: 80, enabled: true,
                                                    onExternalPower: true, currentlyInhibited: false),
                           .applyLimit, "level=\(level)")
        }
    }

    func testChargesWhenBelowLimitAndNotInhibited() {
        XCTAssertEqual(ChargeLimitPolicy.action(level: 79, limit: 80, enabled: true,
                                                onExternalPower: true, currentlyInhibited: false),
                       .releaseLimit)
        XCTAssertEqual(ChargeLimitPolicy.action(level: 20, limit: 80, enabled: true,
                                                onExternalPower: true, currentlyInhibited: false),
                       .releaseLimit)
    }

    /// 迟滞带的核心：已经抑制后，只有回落到 `上限 − 迟滞` 或更低才恢复充电。
    func testHysteresisBandKeepsInhibiting() {
        let limit = 80
        let edge = limit - ChargeLimitPolicy.hysteresisPercent   // 75

        // 迟滞带内（79 / 76）→ 继续抑制，避免阈值附近反复启停。
        XCTAssertEqual(ChargeLimitPolicy.action(level: 79, limit: limit, enabled: true,
                                                onExternalPower: true, currentlyInhibited: true),
                       .applyLimit)
        XCTAssertEqual(ChargeLimitPolicy.action(level: 76, limit: limit, enabled: true,
                                                onExternalPower: true, currentlyInhibited: true),
                       .applyLimit)
        // 恰好落在边界（75 = limit − 迟滞）→ 恢复充电（判定用的是「严格高于」）。
        XCTAssertEqual(ChargeLimitPolicy.action(level: edge, limit: limit, enabled: true,
                                                onExternalPower: true, currentlyInhibited: true),
                       .releaseLimit)
        // 明显回落 → 恢复充电。
        XCTAssertEqual(ChargeLimitPolicy.action(level: 60, limit: limit, enabled: true,
                                                onExternalPower: true, currentlyInhibited: true),
                       .releaseLimit)
    }

    /// 迟滞只在「已经抑制」时才生效：没抑制过时低电量当然是允许充电。
    func testHysteresisOnlyAppliesWhenAlreadyInhibited() {
        XCTAssertEqual(ChargeLimitPolicy.action(level: 76, limit: 80, enabled: true,
                                                onExternalPower: true, currentlyInhibited: false),
                       .releaseLimit)
    }

    /// 把上限从 80 调到 95、而当前电量 85 时应当恢复充电（85 ≤ 95 − 5，出了迟滞带）。
    func testRaisingLimitReleasesCharging() {
        XCTAssertEqual(ChargeLimitPolicy.action(level: 85, limit: 95, enabled: true,
                                                onExternalPower: true, currentlyInhibited: true),
                       .releaseLimit)
    }

    /// 把上限从 100 调到 80、而当前电量 90 时应当立刻抑制（不需要经过迟滞带）。
    func testLoweringLimitInhibitsImmediately() {
        XCTAssertEqual(ChargeLimitPolicy.action(level: 90, limit: 80, enabled: true,
                                                onExternalPower: true, currentlyInhibited: false),
                       .applyLimit)
    }

    func testIsAtLimit() {
        XCTAssertTrue(ChargeLimitPolicy.isAtLimit(level: 80, limit: 80, enabled: true))
        XCTAssertTrue(ChargeLimitPolicy.isAtLimit(level: 88, limit: 80, enabled: true))
        XCTAssertFalse(ChargeLimitPolicy.isAtLimit(level: 79, limit: 80, enabled: true))
        XCTAssertFalse(ChargeLimitPolicy.isAtLimit(level: 80, limit: 80, enabled: false))
        XCTAssertFalse(ChargeLimitPolicy.isAtLimit(level: 100, limit: 100, enabled: true))
    }

    /// 全量扫一遍「任一决策都不该在未接电时要求抑制」，这是最不能出错的一条：
    /// 把一台正在靠电池运行的机器写进「禁止充电」是毫无意义却影响面最大的动作。
    func testNoInhibitDecisionWhileOnBattery() {
        for level in 0...100 {
            for limit in stride(from: ChargeLimitPolicy.minimumPercent,
                                to: ChargeLimitPolicy.maximumPercent,
                                by: ChargeLimitPolicy.stepPercent) {
                let action = ChargeLimitPolicy.action(level: level, limit: limit, enabled: true,
                                                      onExternalPower: false,
                                                      currentlyInhibited: true)
                XCTAssertEqual(action, .noChange, "level=\(level) limit=\(limit)")
            }
        }
    }

    // MARK: - 协议（App ↔ helper）

    func testCommandCarriesProtocolVersionAndRoundTrips() throws {
        let command = ChargeLimitWire.Command(action: .inhibit, limit: 80, timestamp: 1_700_000_000)
        XCTAssertEqual(command.proto, ChargeLimitWire.version)

        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(ChargeLimitWire.Command.self, from: data)
        XCTAssertEqual(decoded, command)
    }

    func testActionRawValuesAreStable() throws {
        // 这两个字符串是**跨进程契约**：helper 是按字面量解析的，改掉就是破坏性变更，
        // 必须同时递增 ChargeLimitWire.version 并让用户重装 helper。
        XCTAssertEqual(ChargeLimitWire.Action.inhibit.rawValue, "inhibit")
        XCTAssertEqual(ChargeLimitWire.Action.allow.rawValue, "allow")
        XCTAssertEqual(try JSONDecoder().decode(ChargeLimitWire.Action.self,
                                               from: Data("\"inhibit\"".utf8)),
                       .inhibit)
    }

    func testStatusRoundTrips() throws {
        let status = ChargeLimitWire.Status(proto: ChargeLimitWire.version,
                                            supported: true,
                                            inhibited: true,
                                            keys: ["CH0B"],
                                            timestamp: 1_700_000_000,
                                            error: nil)
        let data = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(ChargeLimitWire.Status.self, from: data), status)
    }

    /// 回执里的 `error` 允许缺省：helper 正常时不必写这个字段（也能少写几个字节）。
    func testStatusDecodesWithoutOptionalError() throws {
        let json = """
        {"proto":1,"supported":false,"inhibited":false,"keys":[],"timestamp":1}
        """
        let status = try JSONDecoder().decode(ChargeLimitWire.Status.self, from: Data(json.utf8))
        XCTAssertNil(status.error)
        XCTAssertFalse(status.supported)
        // 旧版 helper 不写 probed（新增的可选字段）→ 必须解出 nil 而不是抛错，
        // 否则 App 会把「旧 helper」误判成「读不到回执 = 没装 helper」。
        XCTAssertNil(status.probed)
    }

    func testStatusWithProbesRoundTrips() throws {
        let status = ChargeLimitWire.Status(proto: ChargeLimitWire.version,
                                            supported: false,
                                            inhibited: false,
                                            keys: [],
                                            timestamp: 1_700_000_000,
                                            error: ChargeLimitWire.Status.ErrorCode.noChargeKey,
                                            probed: [ChargeLimitWire.KeyProbe(key: "CH0B",
                                                                              present: true,
                                                                              dataSize: 1,
                                                                              value: 1,
                                                                              used: false)])
        let data = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(ChargeLimitWire.Status.self, from: data), status)
    }

    /// `error` 取值是**跨进程契约**：App 靠它分流到不同的提示（例如区分「机型不支持」
    /// 与「SMC 打不开」）。改字面量就是破坏性变更，两侧必须同时改。
    func testErrorCodeLiteralsAreStable() {
        XCTAssertEqual(ChargeLimitWire.Status.ErrorCode.smcOpenFailed, "smc_open_failed")
        XCTAssertEqual(ChargeLimitWire.Status.ErrorCode.noChargeKey, "no_charge_key")
    }

    // MARK: - 「为什么不可用」的成因区分

    /// 这是本次要修的核心缺陷：三种成因原先在界面上都是同一句「本机不支持」，
    /// 用户既无法处理也无法排查。它们必须分开。
    func testUnavailableReasonDistinguishesCauses() {
        func status(error: String?, probes: [ChargeLimitWire.KeyProbe]?) -> ChargeLimitWire.Status {
            ChargeLimitWire.Status(proto: ChargeLimitWire.version,
                                   supported: false,
                                   inhibited: false,
                                   keys: [],
                                   timestamp: 0,
                                   error: error,
                                   probed: probes)
        }

        // ① 连 SMC 都没打开：环境问题，不是机型不支持。
        XCTAssertEqual(ChargeLimitWire.unavailableReason(
            for: status(error: ChargeLimitWire.Status.ErrorCode.smcOpenFailed, probes: nil)),
                       .smcUnreadable)

        // ② 探测过、一个键都不存在 → 真的没有这些键。
        XCTAssertEqual(ChargeLimitWire.unavailableReason(
            for: status(error: ChargeLimitWire.Status.ErrorCode.noChargeKey,
                        probes: [ChargeLimitWire.KeyProbe(key: "CH0B", present: false,
                                                          dataSize: 0, value: -1, used: false)])),
                       .unsupportedHardware)

        // ③ 旧版 helper 不带 probed → 退回「没有可用键」。
        XCTAssertEqual(ChargeLimitWire.unavailableReason(
            for: status(error: ChargeLimitWire.Status.ErrorCode.noChargeKey, probes: nil)),
                       .unsupportedHardware)

        // ④ 键存在、只是取值不在已知范围内 → 缺一个取值映射（可救），不是没有键。
        XCTAssertEqual(ChargeLimitWire.unavailableReason(
            for: status(error: ChargeLimitWire.Status.ErrorCode.noChargeKey,
                        probes: [ChargeLimitWire.KeyProbe(key: "CH0B", present: true,
                                                          dataSize: 1, value: 1, used: false)])),
                       .unrecognizedValues)

        // ⑤ smc_open_failed 优先级最高：即使带着探测结果也按环境问题处理。
        XCTAssertEqual(ChargeLimitWire.unavailableReason(
            for: status(error: ChargeLimitWire.Status.ErrorCode.smcOpenFailed,
                        probes: [ChargeLimitWire.KeyProbe(key: "CH0B", present: true,
                                                          dataSize: 1, value: 0, used: false)])),
                       .smcUnreadable)
    }

    /// 探测摘要要能一眼看出「不存在 / 不是单字节 / 取值是多少」三件事。
    func testKeyProbeSummary() {
        XCTAssertEqual(ChargeLimitWire.KeyProbe(key: "CHTE", present: false, dataSize: 0,
                                               value: -1, used: false).summary,
                       "CHTE=missing")
        XCTAssertEqual(ChargeLimitWire.KeyProbe(key: "CH0B", present: true, dataSize: 1,
                                               value: 2, used: true).summary,
                       "CH0B=0x02")
        XCTAssertEqual(ChargeLimitWire.KeyProbe(key: "CH0B", present: true, dataSize: 1,
                                               value: 1, used: false).summary,
                       "CH0B=0x01")
        XCTAssertEqual(ChargeLimitWire.KeyProbe(key: "BCLM", present: true, dataSize: 4,
                                               value: 50, used: false).summary,
                       "BCLM=size4:50")
    }

    /// 枚举过滤器：只收 4 字符、前缀命中的键名。
    ///
    /// 枚举是为了**不再靠猜键名**，所以前缀刻意放宽（见过 CH0B/CH0C/CHTE/BCLM/BFCL/ACEN
    /// 这些形态）；但长度必须恰好 4 —— 长度不对说明枚举出来的东西不是键名
    /// （协议或字节序理解有误），宁可丢掉也不把垃圾当键名上报。
    func testChargeRelatedKeyFilter() {
        for name in ["CH0B", "CH0C", "CHTE", "CHWA", "BCLM", "BFCL", "ACEN"] {
            XCTAssertTrue(ChargeLimitWire.isChargeRelatedKey(name), name)
        }
        for name in ["PSTR", "#KEY", "CH0", "CH0BB", "ch0b", "", "F0Ac"] {
            XCTAssertFalse(ChargeLimitWire.isChargeRelatedKey(name), name)
        }
    }

    /// 枚举结果会随每秒一次的回执一起落盘，必须限量，否则会把 /tmp 写爆。
    func testEnumeratedKeyLimitIsBounded() {
        XCTAssertGreaterThan(ChargeLimitWire.enumeratedKeyLimit, 0)
        XCTAssertLessThanOrEqual(ChargeLimitWire.enumeratedKeyLimit, 64)
    }

    // MARK: - 「最大充电量」机制（BCLM）

    /// 与抑制机制**必须**分开决策：BCLM 是持久的上限值，按电量来回切会在电量回落时
    /// 把上限整个撤掉（写回 100），电池就一路充回 100% 了。
    func testLevelCapActionIgnoresBatteryLevel() {
        // 只看"要不要限制"：启用且上限 < 100 → 施加。
        XCTAssertEqual(ChargeLimitPolicy.levelCapAction(enabled: true, limit: 80), .applyLimit)
        XCTAssertEqual(ChargeLimitPolicy.levelCapAction(enabled: true, limit: 50), .applyLimit)
        XCTAssertEqual(ChargeLimitPolicy.levelCapAction(enabled: true, limit: 95), .applyLimit)
        // 关闭 / 上限 100 → 解除（写回 100）。
        XCTAssertEqual(ChargeLimitPolicy.levelCapAction(enabled: false, limit: 80), .releaseLimit)
        XCTAssertEqual(ChargeLimitPolicy.levelCapAction(enabled: true, limit: 100), .releaseLimit)
    }

    /// 同一条指令下两套机制的结论可以不同 —— 这正是要分开的原因，钉住这个差异。
    func testTwoMechanismsCanDisagreeOnTheSameInput() {
        // 电量已回落到迟滞带以下、且此前已限制：
        // 抑制机制 → 恢复充电；最大充电量机制 → 继续保持上限。
        let inhibitDecision = ChargeLimitPolicy.action(level: 70, limit: 80, enabled: true,
                                                       onExternalPower: true,
                                                       currentlyInhibited: true)
        XCTAssertEqual(inhibitDecision, .releaseLimit)
        XCTAssertEqual(ChargeLimitPolicy.levelCapAction(enabled: true, limit: 80), .applyLimit)
    }

    /// helper 的最后一道护栏：指令文件来自全局可写的 `/tmp`，越界值宁可拒绝执行。
    func testIsWritableRejectsOutOfRange() {
        XCTAssertTrue(ChargeLimitPolicy.isWritable(50))
        XCTAssertTrue(ChargeLimitPolicy.isWritable(80))
        XCTAssertTrue(ChargeLimitPolicy.isWritable(100))
        XCTAssertFalse(ChargeLimitPolicy.isWritable(49))
        XCTAssertFalse(ChargeLimitPolicy.isWritable(101))
        XCTAssertFalse(ChargeLimitPolicy.isWritable(0))
        XCTAssertFalse(ChargeLimitPolicy.isWritable(-80))
    }

    // MARK: - 机制上报

    func testMechanismRawValuesAreStable() throws {
        // 跨进程契约：helper 按字面量读写，改掉即破坏性变更。
        XCTAssertEqual(ChargeLimitWire.Mechanism.inhibit.rawValue, "inhibit")
        XCTAssertEqual(ChargeLimitWire.Mechanism.bclm.rawValue, "bclm")
        XCTAssertEqual(try JSONDecoder().decode(ChargeLimitWire.Mechanism.self,
                                               from: Data("\"bclm\"".utf8)),
                       .bclm)
    }

    /// 旧版 helper 的回执不带 `mechanism` → 必须解出 nil（App 据此按抑制机制理解），
    /// 而不是解析失败 —— 否则"App 升级了、helper 还没重装"会被误判成协议不兼容。
    func testStatusWithoutMechanismDecodesToNil() throws {
        let json = """
        {"proto":1,"supported":true,"inhibited":false,"keys":["CH0B"],"timestamp":1}
        """
        let status = try JSONDecoder().decode(ChargeLimitWire.Status.self, from: Data(json.utf8))
        XCTAssertNil(status.mechanism)
        XCTAssertNil(status.probed)
    }

    func testStatusWithMechanismRoundTrips() throws {
        let status = ChargeLimitWire.Status(proto: ChargeLimitWire.version,
                                            supported: true,
                                            inhibited: true,
                                            keys: ["BCLM"],
                                            timestamp: 1_700_000_000,
                                            error: nil,
                                            probed: [ChargeLimitWire.KeyProbe(key: "BCLM",
                                                                              present: true,
                                                                              dataSize: 1,
                                                                              value: 80,
                                                                              used: true)],
                                            mechanism: .bclm)
        let data = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(ChargeLimitWire.Status.self, from: data), status)
    }

    /// 越界错误码也是跨进程契约（App 侧不进文案分支，但会进日志）。
    func testLimitOutOfRangeErrorCode() {
        XCTAssertEqual(ChargeLimitWire.Status.ErrorCode.limitOutOfRange, "limit_out_of_range")
    }

    func testWirePathsAndWindows() {
        XCTAssertTrue(ChargeLimitWire.commandPath.hasPrefix("/tmp/"))
        XCTAssertTrue(ChargeLimitWire.statusPath.hasPrefix("/tmp/"))
        XCTAssertNotEqual(ChargeLimitWire.commandPath, ChargeLimitWire.statusPath)
        // 心跳必须显著早于新鲜度窗口，否则一次丢拍就会被判定成「App 已退出」而误复位。
        XCTAssertLessThan(ChargeLimitWire.heartbeatInterval, ChargeLimitWire.commandFreshness)
    }
}
