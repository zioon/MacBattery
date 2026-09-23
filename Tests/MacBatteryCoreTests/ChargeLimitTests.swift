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
                           .inhibitCharging, "level=\(level)")
        }
    }

    func testChargesWhenBelowLimitAndNotInhibited() {
        XCTAssertEqual(ChargeLimitPolicy.action(level: 79, limit: 80, enabled: true,
                                                onExternalPower: true, currentlyInhibited: false),
                       .allowCharging)
        XCTAssertEqual(ChargeLimitPolicy.action(level: 20, limit: 80, enabled: true,
                                                onExternalPower: true, currentlyInhibited: false),
                       .allowCharging)
    }

    /// 迟滞带的核心：已经抑制后，只有回落到 `上限 − 迟滞` 或更低才恢复充电。
    func testHysteresisBandKeepsInhibiting() {
        let limit = 80
        let edge = limit - ChargeLimitPolicy.hysteresisPercent   // 75

        // 迟滞带内（79 / 76）→ 继续抑制，避免阈值附近反复启停。
        XCTAssertEqual(ChargeLimitPolicy.action(level: 79, limit: limit, enabled: true,
                                                onExternalPower: true, currentlyInhibited: true),
                       .inhibitCharging)
        XCTAssertEqual(ChargeLimitPolicy.action(level: 76, limit: limit, enabled: true,
                                                onExternalPower: true, currentlyInhibited: true),
                       .inhibitCharging)
        // 恰好落在边界（75 = limit − 迟滞）→ 恢复充电（判定用的是「严格高于」）。
        XCTAssertEqual(ChargeLimitPolicy.action(level: edge, limit: limit, enabled: true,
                                                onExternalPower: true, currentlyInhibited: true),
                       .allowCharging)
        // 明显回落 → 恢复充电。
        XCTAssertEqual(ChargeLimitPolicy.action(level: 60, limit: limit, enabled: true,
                                                onExternalPower: true, currentlyInhibited: true),
                       .allowCharging)
    }

    /// 迟滞只在「已经抑制」时才生效：没抑制过时低电量当然是允许充电。
    func testHysteresisOnlyAppliesWhenAlreadyInhibited() {
        XCTAssertEqual(ChargeLimitPolicy.action(level: 76, limit: 80, enabled: true,
                                                onExternalPower: true, currentlyInhibited: false),
                       .allowCharging)
    }

    /// 把上限从 80 调到 95、而当前电量 85 时应当恢复充电（85 ≤ 95 − 5，出了迟滞带）。
    func testRaisingLimitReleasesCharging() {
        XCTAssertEqual(ChargeLimitPolicy.action(level: 85, limit: 95, enabled: true,
                                                onExternalPower: true, currentlyInhibited: true),
                       .allowCharging)
    }

    /// 把上限从 100 调到 80、而当前电量 90 时应当立刻抑制（不需要经过迟滞带）。
    func testLoweringLimitInhibitsImmediately() {
        XCTAssertEqual(ChargeLimitPolicy.action(level: 90, limit: 80, enabled: true,
                                                onExternalPower: true, currentlyInhibited: false),
                       .inhibitCharging)
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
    }

    func testWirePathsAndWindows() {
        XCTAssertTrue(ChargeLimitWire.commandPath.hasPrefix("/tmp/"))
        XCTAssertTrue(ChargeLimitWire.statusPath.hasPrefix("/tmp/"))
        XCTAssertNotEqual(ChargeLimitWire.commandPath, ChargeLimitWire.statusPath)
        // 心跳必须显著早于新鲜度窗口，否则一次丢拍就会被判定成「App 已退出」而误复位。
        XCTAssertLessThan(ChargeLimitWire.heartbeatInterval, ChargeLimitWire.commandFreshness)
    }
}
