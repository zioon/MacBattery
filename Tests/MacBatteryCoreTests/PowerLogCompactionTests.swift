import XCTest
@testable import MacBatteryCore

/// 功率日志的落盘压缩（定点化 + 变化门控）测试。
///
/// 这块逻辑决定「哪些数据被永久丢弃」，一旦判据写错就是静默的历史丢失，
/// 因此每个分支都要覆盖 —— 且这些测试是本机（无 Swift 工具链）之外唯一的验证通道。
final class PowerLogCompactionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_758_000_000)

    private func record(offsetSeconds: Double,
                        battery: Int = 85,
                        charging: Bool = false,
                        milliWatts: Int = 0,
                        milliVolts: Int = 0,
                        milliAmps: Int = 0,
                        cpu: Int = 10,
                        memory: Int = 50,
                        systemMilliWatts: Int = 8000) -> PowerSampleRecord {
        PowerSampleRecord(epochMilliseconds: Int((t0.timeIntervalSince1970 + offsetSeconds) * 1000),
                          batteryPercent: battery,
                          isCharging: charging,
                          chargingMilliWatts: milliWatts,
                          chargingMilliVolts: milliVolts,
                          chargingMilliAmps: milliAmps,
                          cpuPercent: cpu,
                          memoryPercent: memory,
                          systemMilliWatts: systemMilliWatts)
    }

    // MARK: - 定点化

    func testFixedPointRoundsAndScales() {
        let r = PowerSampleRecord(t: t0,
                                  batteryPercent: 85,
                                  isCharging: true,
                                  chargingWatts: 12.3456,
                                  chargingVoltage: 12.1,
                                  chargingCurrent: 1.0245,
                                  cpuUsage: 0.432,
                                  memoryUsage: 0.876,
                                  systemWatts: 8.7654)
        XCTAssertEqual(r.epochMilliseconds, 1_758_000_000_000)
        XCTAssertEqual(r.chargingMilliWatts, 12346)
        XCTAssertEqual(r.chargingMilliVolts, 12100)
        XCTAssertEqual(r.chargingMilliAmps, 1025)
        XCTAssertEqual(r.cpuPercent, 43)
        XCTAssertEqual(r.memoryPercent, 88)
        XCTAssertEqual(r.systemMilliWatts, 8765)
    }

    /// 毫秒时间戳必须让 0.5s 间隔的采样互不相同 —— 否则回填时 `mergedByTimestamp`
    /// 会按相同时间戳去重，把两条历史合并成一条（静默丢样本）。
    func testMillisecondTimestampsAreDistinctAtHalfSecondInterval() {
        var stamps: Set<Int> = []
        for i in 0..<1000 {
            let r = PowerSampleRecord(t: t0.addingTimeInterval(Double(i) * 0.5),
                                      batteryPercent: 85, isCharging: false,
                                      chargingWatts: 0, chargingVoltage: 0, chargingCurrent: 0,
                                      cpuUsage: 0.1, memoryUsage: 0.5, systemWatts: 8)
            stamps.insert(r.epochMilliseconds)
        }
        XCTAssertEqual(stamps.count, 1000, "0.5s 间隔的采样必须得到互不相同的时间戳")
    }

    /// 落盘数据会被读回来直接进图表，异常读数必须被夹取，否则画成尖峰。
    func testOutOfRangeValuesAreClamped() {
        let r = PowerSampleRecord(t: t0,
                                  batteryPercent: 140,
                                  isCharging: false,
                                  chargingWatts: -5,
                                  chargingVoltage: .nan,
                                  chargingCurrent: .infinity,
                                  cpuUsage: 1.4,
                                  memoryUsage: -0.3,
                                  systemWatts: -1)
        XCTAssertEqual(r.batteryPercent, 100)
        XCTAssertEqual(r.chargingMilliWatts, 0, "负瓦数应归零")
        XCTAssertEqual(r.chargingMilliVolts, 0, "NaN 应归零")
        XCTAssertEqual(r.chargingMilliAmps, 0, "infinity 应归零（而不是 Int.max 尖峰）")
        XCTAssertEqual(r.cpuPercent, 100)
        XCTAssertEqual(r.memoryPercent, 0)
        XCTAssertEqual(r.systemMilliWatts, 0)
    }

    // MARK: - 变化门控

    func testFirstRecordAlwaysPersists() {
        XCTAssertTrue(PowerLogGate.default.shouldPersist(previous: nil, current: record(offsetSeconds: 0)))
    }

    func testIdenticalValueWithinToleranceIsDropped() {
        let prev = record(offsetSeconds: 0)
        // 系统功率抖动 1.9W < 2W 容差，CPU 抖动 1 < 2 个百分点。
        let next = record(offsetSeconds: 0.5, systemMilliWatts: 9900, cpu: 11)
        XCTAssertFalse(PowerLogGate.default.shouldPersist(previous: prev, current: next))
    }

    func testBatteryChangeAlwaysPersists() {
        let prev = record(offsetSeconds: 0, battery: 85)
        let next = record(offsetSeconds: 0.5, battery: 84)
        XCTAssertTrue(PowerLogGate.default.shouldPersist(previous: prev, current: next))
    }

    func testChargingFlagChangeAlwaysPersists() {
        let prev = record(offsetSeconds: 0, charging: false)
        let next = record(offsetSeconds: 0.5, charging: true)
        XCTAssertTrue(PowerLogGate.default.shouldPersist(previous: prev, current: next))
    }

    func testChangeBeyondTolerancePersists() {
        let prev = record(offsetSeconds: 0, cpu: 10)
        let next = record(offsetSeconds: 0.5, cpu: 12)   // 恰好达到 2 个百分点容差
        XCTAssertTrue(PowerLogGate.default.shouldPersist(previous: prev, current: next))
    }

    /// 基线兜底：数值完全平直时也必须按时间留点，否则历史里会出现长时间空档。
    func testBaselineIntervalForcesARecordWhenFlat() {
        let prev = record(offsetSeconds: 0)
        let justBefore = record(offsetSeconds: 59.5)
        let atBaseline = record(offsetSeconds: 60)
        XCTAssertFalse(PowerLogGate.default.shouldPersist(previous: prev, current: justBefore),
                       "未到基线间隔且无变化时应丢弃")
        XCTAssertTrue(PowerLogGate.default.shouldPersist(previous: prev, current: atBaseline),
                      "达到基线间隔时应强制留一条")
    }

    /// 时钟回拨后差值为负，基线判据会永远不成立 —— 必须强制写一条把基准拉回来。
    func testClockRewindForcesRecord() {
        let prev = record(offsetSeconds: 100)
        let rewound = record(offsetSeconds: 10)
        XCTAssertTrue(PowerLogGate.default.shouldPersist(previous: prev, current: rewound))
    }

    /// 端到端模拟：稳态下写入率应降到约 1/基线间隔，这是本次改动的核心收益。
    func testSteadyStateWriteRateIsDrasticallyReduced() {
        let gate = PowerLogGate.default
        var previous: PowerSampleRecord?
        var written = 0
        // 2 小时稳态：每 0.5s 一采，共 14400 次采样。
        for i in 0..<14_400 {
            let current = record(offsetSeconds: Double(i) * 0.5)
            if gate.shouldPersist(previous: previous, current: current) {
                previous = current
                written += 1
            }
        }
        // 2h / 60s = 120 条基线记录。
        XCTAssertEqual(written, 120, "稳态 14400 次采样应只落盘约 120 条")
        XCTAssertLessThan(written, 14_400 / 100, "写入率应下降两个数量级以上")
    }

    /// 变化门控不能把「充电开始 / 结束」这种关键转折漏掉 ——
    /// 这类事件即使发生在两条基线记录之间也必须留下。
    func testChargingTransitionIsNeverLost() {
        let gate = PowerLogGate.default
        var previous: PowerSampleRecord?
        var written: [PowerSampleRecord] = []
        // 400 次采样 = 200s，足以覆盖「首条 + 转折点 + 转折后 60s 基线」三条。
        for i in 0..<400 {
            // 第 100 次采样（t=50s，未到 60s 基线）开始充电。
            let charging = i >= 100
            let current = record(offsetSeconds: Double(i) * 0.5, charging: charging, milliWatts: charging ? 4500 : 0)
            if gate.shouldPersist(previous: previous, current: current) {
                previous = current
                written.append(current)
            }
        }
        // 400 次采样 = 200s，落盘点为 t=0（首条）、t=50（充电转折）、
        // t=110 与 t=170（转折后每 60s 的基线兜底）。
        XCTAssertEqual(written.map { Double($0.epochMilliseconds - Int(t0.timeIntervalSince1970 * 1000)) / 1000 },
                       [0, 50, 110, 170],
                       "稳态段应只有 60s 基线点，充电转折必须插进来")
        XCTAssertFalse(written[0].isCharging)
        XCTAssertTrue(written[1].isCharging, "充电开始必须被记录，即使未到基线间隔")
        XCTAssertEqual(written[1].epochMilliseconds, record(offsetSeconds: 50).epochMilliseconds)
    }

    // MARK: - 编解码

    func testRoundTripThroughLine() {
        let original = record(offsetSeconds: 123.456, battery: 73, charging: true,
                              milliWatts: 12345, milliVolts: 12100, milliAmps: 1025,
                              cpu: 43, memory: 88, systemMilliWatts: 8765)
        let line = PowerLogEncoding.line(original).dropLast()   // 去掉换行符
        XCTAssertEqual(PowerLogEncoding.parseV2(line), original)
    }

    /// v1 与 v2 列数相同，格式版本必须靠文件名区分 —— 逐列启发式会有歧义
    /// （旧格式里恰好是整数的瓦数会被当成 milli 量纲，错一个数量级）。
    /// 因此 v2 解析器必须**拒绝**任何含小数点的行。
    func testParseV2RejectsLegacyFullPrecisionLine() {
        let v1 = "1758000000.123456,85,1,12.345000000000001,12.100000000000001,1.0249999,0.43200000000000004,0.876,8.7654"
        XCTAssertNil(PowerLogEncoding.parseV2(Substring(v1)),
                     "v2 解析器必须拒绝含小数的 v1 行：猜错就是错一个数量级的历史")
    }

    func testParseV1RecoversLegacyLine() {
        let v1 = "1758000000.5,85,1,12.345,12.1,1.0249,0.432,0.876,8.765"
        guard let r = PowerLogEncoding.parseV1(Substring(v1)) else {
            return XCTFail("v1 行必须能被 v1 解析器读回，否则升级会丢历史")
        }
        XCTAssertEqual(r.batteryPercent, 85)
        XCTAssertEqual(r.chargingMilliWatts, 12345)
        XCTAssertEqual(r.cpuPercent, 43)
        XCTAssertEqual(r.systemMilliWatts, 8765)
        XCTAssertEqual(r.timestamp.timeIntervalSince1970, 1_758_000_000.5, accuracy: 0.001)
    }

    func testParseRejectsHeaderAndInvalidEpoch() {
        XCTAssertNil(PowerLogEncoding.parseV2(Substring(PowerLogEncoding.headerV2.dropLast())))
        XCTAssertNil(PowerLogEncoding.parseV1(Substring(PowerLogEncoding.headerV1.dropLast())))
        XCTAssertNil(PowerLogEncoding.parseV2(Substring("0,85,0,0,0,0,10,50,8000")),
                     "早于 2000 年的时间戳是无效行")
    }

    func testParseRejectsWrongColumnCount() {
        XCTAssertNil(PowerLogEncoding.parseV2(Substring("1758000000000,85,0")))
        XCTAssertNil(PowerLogEncoding.parseV1(Substring("1758000000.0,85,0")))
    }

    /// 定点格式下单行约 46 字节 —— 这是本次改动的量化目标，门禁化防止回退。
    func testLineWidthStaysCompact() {
        let line = PowerLogEncoding.line(record(offsetSeconds: 123.456, battery: 100, charging: true,
                                                milliWatts: 65432, milliVolts: 65432, milliAmps: 65432,
                                                cpu: 100, memory: 100, systemMilliWatts: 65432))
        XCTAssertLessThanOrEqual(line.utf8.count, 64,
                                 "定点格式单行应保持在 ~46 字节；变长说明精度被意外放开了")
    }
}
