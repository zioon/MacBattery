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
                        systemMilliWatts: Int = 8000,
                        external: Bool? = nil,
                        temperatureDeci: Int? = nil,
                        remaining: Int? = nil,
                        capacity: Int? = nil,
                        fully: Bool? = nil) -> PowerSampleRecord {
        PowerSampleRecord(epochMilliseconds: Int((t0.timeIntervalSince1970 + offsetSeconds) * 1000),
                          batteryPercent: battery,
                          isCharging: charging,
                          chargingMilliWatts: milliWatts,
                          chargingMilliVolts: milliVolts,
                          chargingMilliAmps: milliAmps,
                          cpuPercent: cpu,
                          memoryPercent: memory,
                          systemMilliWatts: systemMilliWatts,
                          externalPower: external,
                          temperatureDeciCelsius: temperatureDeci,
                          remainingMinutes: remaining,
                          currentCapacityMilliAmpHours: capacity,
                          fullyCharged: fully)
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

    /// 新增遥测字段的定点化：温度 0.1℃、容量 mAh、剩余分钟、充满标志。
    func testTelemetryFixedPointConversion() {
        let r = PowerSampleRecord(t: t0,
                                  batteryPercent: 83,
                                  isCharging: false,
                                  chargingWatts: 0,
                                  chargingVoltage: 12.017,
                                  chargingCurrent: 1.024,
                                  cpuUsage: 0.1,
                                  memoryUsage: 0.5,
                                  systemWatts: 8,
                                  externalPower: false,
                                  temperatureCelsius: 31.04,
                                  remainingMinutes: 395,
                                  currentCapacity: 4117,
                                  fullyCharged: false)
        XCTAssertEqual(r.temperatureDeciCelsius, 310)
        XCTAssertEqual(r.remainingMinutes, 395)
        XCTAssertEqual(r.currentCapacityMilliAmpHours, 4117)
        XCTAssertEqual(r.fullyCharged, false)
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
                                  systemWatts: -1,
                                  temperatureCelsius: .nan,
                                  currentCapacity: 0)
        XCTAssertEqual(r.batteryPercent, 100)
        XCTAssertEqual(r.chargingMilliWatts, 0, "负瓦数应归零")
        XCTAssertEqual(r.chargingMilliVolts, 0, "NaN 应归零")
        XCTAssertEqual(r.chargingMilliAmps, 0, "infinity 应归零（而不是 Int.max 尖峰）")
        XCTAssertEqual(r.cpuPercent, 100)
        XCTAssertEqual(r.memoryPercent, 0)
        XCTAssertEqual(r.systemMilliWatts, 0)
        XCTAssertNil(r.temperatureDeciCelsius, "NaN 温度必须是「未知」，不能画成 0℃")
        XCTAssertNil(r.currentCapacityMilliAmpHours, "0 mAh 是无效读数，必须记为未知")
    }

    // MARK: - 变化门控

    func testFirstRecordAlwaysPersists() {
        XCTAssertTrue(PowerLogGate.default.shouldPersist(previous: nil, current: record(offsetSeconds: 0)))
    }

    func testIdenticalValueWithinToleranceIsDropped() {
        let prev = record(offsetSeconds: 0)
        // 系统功率抖动 1.9W < 2W 容差，CPU 抖动 1 < 2 个百分点。
        let next = record(offsetSeconds: 0.5, cpu: 11, systemMilliWatts: 9900)
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

    /// 插拔电源同样必须立即留痕：否则图表上充电 / 接电时段带的边界会被基线间隔拉偏。
    func testExternalPowerChangeAlwaysPersists() {
        let prev = record(offsetSeconds: 0, external: false)
        let next = record(offsetSeconds: 0.5, external: true)
        XCTAssertTrue(PowerLogGate.default.shouldPersist(previous: prev, current: next))
    }

    /// 温度跨越 1℃ 必须立即留痕，否则尖锐的发热段会被 60s 基线削平。
    func testTemperatureChangeBeyondTolerancePersists() {
        let prev = record(offsetSeconds: 0, temperatureDeci: 3105)
        let next = record(offsetSeconds: 0.5, temperatureDeci: 3115)   // +1.0℃
        XCTAssertTrue(PowerLogGate.default.shouldPersist(previous: prev, current: next))

        let tiny = record(offsetSeconds: 0.5, temperatureDeci: 3109)   // +0.4℃
        XCTAssertFalse(PowerLogGate.default.shouldPersist(previous: prev, current: tiny),
                       "1℃ 以内的温度抖动视为噪声")
    }

    /// 「已充满 ↔ 未充满」是充电器行为的边界，必须立即记录。
    func testFullyChargedTransitionAlwaysPersists() {
        let prev = record(offsetSeconds: 0, fully: false)
        let next = record(offsetSeconds: 0.5, fully: true)
        XCTAssertTrue(PowerLogGate.default.shouldPersist(previous: prev, current: next))
    }

    /// 剩余时间与 mAh 是**随行载荷**，单独变化不应抬高写入率（靠 60s 基线兜底）。
    func testRemainingAndCapacityAloneDoNotForcePersist() {
        let prev = record(offsetSeconds: 0, remaining: 395, capacity: 4117)
        let next = record(offsetSeconds: 0.5, remaining: 330, capacity: 4100)
        XCTAssertFalse(PowerLogGate.default.shouldPersist(previous: prev, current: next))
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

    /// 后加的 `externalPower` 列必须能原样往返（含「未知」）。
    func testExternalPowerRoundTrips() {
        for external in [true, false, nil] as [Bool?] {
            let original = record(offsetSeconds: 1, external: external)
            let line = PowerLogEncoding.line(original).dropLast()
            XCTAssertEqual(PowerLogEncoding.parseV2(line), original,
                           "externalPower=\(String(describing: external)) 必须能原样读回")
        }
    }

    /// 新增的遥测列必须能原样往返（含「未知」与 -1 / -2 哨兵）。
    func testTelemetryColumnsRoundTrip() {
        let cases: [(Int?, Int?, Int?, Bool?)] = [
            (374, 395, 4117, false),      // 37.4℃
            (0, -2, nil, true),           // 0℃ 与 -2（接通电源）都是有效值
            (nil, -1, nil, nil),
            (nil, nil, nil, nil)
        ]
        for (temperature, remaining, capacity, fully) in cases {
            let original = record(offsetSeconds: 3,
                                  temperatureDeci: temperature,
                                  remaining: remaining,
                                  capacity: capacity,
                                  fully: fully)
            let line = PowerLogEncoding.line(original).dropLast()
            XCTAssertEqual(PowerLogEncoding.parseV2(line), original,
                           "遥测列往返失败: temp=\(String(describing: temperature)) "
                           + "remaining=\(String(describing: remaining)) "
                           + "capacity=\(String(describing: capacity)) "
                           + "fully=\(String(describing: fully))")
        }
    }

    /// 升级前的 10 列行没有遥测列，必须读成「未知」，不能默认成 0℃ / 0 mAh / 未充满。
    func testParseV2ReadsLegacyTenColumnRowWithoutTelemetry() {
        let legacy = "1758000000000,85,0,0,0,0,10,50,8000,0"
        guard let r = PowerLogEncoding.parseV2(Substring(legacy)) else {
            return XCTFail("10 列旧行必须仍能解析，否则升级会丢历史")
        }
        XCTAssertNil(r.temperatureDeciCelsius)
        XCTAssertNil(r.remainingMinutes)
        XCTAssertNil(r.currentCapacityMilliAmpHours)
        XCTAssertNil(r.fullyCharged)
    }

    /// 逐级扩展的 11–13 列行也要能读，缺失的尾列保持未知。
    func testParseV2ReadsPartiallyExtendedRows() {
        let eleven = "1758000000000,85,0,0,0,0,10,50,8000,0,374"
        guard let r11 = PowerLogEncoding.parseV2(Substring(eleven)) else {
            return XCTFail("11 列行必须能解析")
        }
        XCTAssertEqual(r11.temperatureDeciCelsius, 374)
        XCTAssertNil(r11.remainingMinutes)
        XCTAssertNil(r11.fullyCharged)

        let twelve = "1758000000000,85,0,0,0,0,10,50,8000,0,374,395"
        guard let r12 = PowerLogEncoding.parseV2(Substring(twelve)) else {
            return XCTFail("12 列行必须能解析")
        }
        XCTAssertEqual(r12.remainingMinutes, 395)
        XCTAssertNil(r12.currentCapacityMilliAmpHours)

        let thirteen = "1758000000000,85,0,0,0,0,10,50,8000,0,374,395,4117"
        guard let r13 = PowerLogEncoding.parseV2(Substring(thirteen)) else {
            return XCTFail("13 列行必须能解析")
        }
        XCTAssertEqual(r13.currentCapacityMilliAmpHours, 4117)
        XCTAssertNil(r13.fullyCharged)
    }

    /// v1.5.0 早期的温度量纲错误：落盘值等于注册表原始值（不是 ℃）。
    /// 读取时必须按本机量纲换算回来，且换算后仍不可能的坏值记为未知。
    func testParseV2RepairsLegacyRawTemperature() {
        func parse(_ temperature: String) -> PowerSampleRecord? {
            PowerLogEncoding.parseV2(
                Substring("1758000000000,85,0,0,0,0,10,50,8000,0,\(temperature)"))
        }

        // 3105 的还原结果随硬件量纲不同：Intel 310.5K = 37.35℃ → 374；Apple silicon → 311。
        let repaired: Int = BatteryTemperature.isAppleSilicon ? 311 : 374
        guard let legacy = parse("3105") else { return XCTFail("11 列行必须能解析") }
        XCTAssertEqual(legacy.temperatureDeciCelsius, repaired,
                       "旧原始值 3105 必须按本机量纲还原，而不是当成 310℃")

        guard let normal = parse("374") else { return XCTFail("11 列行必须能解析") }
        XCTAssertEqual(normal.temperatureDeciCelsius, 374, "新版正确值必须原样保留")

        guard let zero = parse("0") else { return XCTFail("11 列行必须能解析") }
        XCTAssertEqual(zero.temperatureDeciCelsius, 0, "0℃ 仍是有效读数")

        guard let garbage = parse("12345") else { return XCTFail("11 列行必须能解析") }
        XCTAssertNil(garbage.temperatureDeciCelsius, "换算后仍不可能的读数必须记为未知")
    }

    /// 两种量纲的换算与旧值修正：显式指定 scale，测试结果不依赖跑测机器的架构。
    func testTemperatureScaleConversionAndLegacyRepair() {
        // Intel：0.1K → ℃。
        XCTAssertEqual(BatteryTemperature.celsius(fromRaw: 3105, scale: .deciKelvin) ?? .nan,
                       37.35, accuracy: 0.001)
        // Apple silicon：0.01℃ → ℃。
        XCTAssertEqual(BatteryTemperature.celsius(fromRaw: 3105, scale: .centiCelsius) ?? .nan,
                       31.05, accuracy: 0.001)

        // 超出合理区间（-20…80℃）的读数一律视为未知。
        XCTAssertNil(BatteryTemperature.celsius(fromRaw: 12_345, scale: .deciKelvin))
        XCTAssertNil(BatteryTemperature.celsius(fromRaw: 12_345, scale: .centiCelsius))
        XCTAssertNil(BatteryTemperature.celsius(fromRaw: 0, scale: .deciKelvin), "0K = -273℃ 不可能")

        // 旧落盘值 = 注册表原始值，读取时按量纲还原成 0.1℃ 定点。
        XCTAssertEqual(BatteryTemperature.repairedDeci(3105, scale: .deciKelvin), 374)
        XCTAssertEqual(BatteryTemperature.repairedDeci(3105, scale: .centiCelsius), 311)
        // 已是合法新值的行原样保留。
        XCTAssertEqual(BatteryTemperature.repairedDeci(374, scale: .deciKelvin), 374)
        XCTAssertEqual(BatteryTemperature.repairedDeci(0, scale: .centiCelsius), 0)
        // 还原后仍不可能 → 未知。
        XCTAssertNil(BatteryTemperature.repairedDeci(12_345, scale: .deciKelvin))
        XCTAssertNil(BatteryTemperature.repairedDeci(-5000, scale: .deciKelvin))
    }

    /// 空列表示未知，非空的非法整数必须让整行作废（不能猜成 0）。
    func testParseV2HandlesEmptyAndMalformedTelemetryColumns() {
        let empty = "1758000000000,85,0,0,0,0,10,50,8000,0,,,"
        guard let r = PowerLogEncoding.parseV2(Substring(empty)) else {
            return XCTFail("空遥测列应解析为未知")
        }
        XCTAssertNil(r.temperatureDeciCelsius)
        XCTAssertNil(r.remainingMinutes)
        XCTAssertNil(r.currentCapacityMilliAmpHours)
        XCTAssertNil(r.fullyCharged)

        let malformed = "1758000000000,85,0,0,0,0,10,50,8000,0,31.05"
        XCTAssertNil(PowerLogEncoding.parseV2(Substring(malformed)),
                     "小数温度不属于定点格式，整行应作废")
    }

    /// 升级前写入的 9 列 v2 行没有外电字段，必须能解析为「未知」——
    /// 若默认成 false，旧历史会被图表画成「用电池」。
    func testParseV2ReadsLegacyNineColumnRowAsUnknown() {
        let legacy = "1758000000000,85,0,0,0,0,10,50,8000"
        guard let r = PowerLogEncoding.parseV2(Substring(legacy)) else {
            return XCTFail("9 列旧行必须仍能解析，否则升级会丢历史")
        }
        XCTAssertNil(r.externalPower)
        XCTAssertEqual(r.batteryPercent, 85)
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
        // ⚠️ 时间戳必须保留小数部分：截断到整秒会让同一秒内的两条 v1 样本
        // 拿到相同时间戳，回填去重时丢掉一半历史（0.5s 采样 → 每秒丢 1 条）。
        XCTAssertEqual(r.timestamp.timeIntervalSince1970, 1_758_000_000.5, accuracy: 0.001)
    }

    /// 同一秒内两条 v1 记录（0.5s 采样）解析后时间戳必须互不相同，
    /// 否则回填时会被 `mergedByTimestamp` 当成重复项去掉。
    func testParseV1KeepsSubSecondResolution() {
        let a = "1758000000.000000,85,0,0,0,0,0.4,0.8,8.0"
        let b = "1758000000.500000,85,0,0,0,0,0.4,0.8,8.0"
        guard let ra = PowerLogEncoding.parseV1(Substring(a)),
              let rb = PowerLogEncoding.parseV1(Substring(b)) else {
            return XCTFail("两行都应解析成功")
        }
        XCTAssertNotEqual(ra.epochMilliseconds, rb.epochMilliseconds,
                          "相差 0.5s 的两条 v1 记录必须得到不同时间戳")
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

    /// 定点格式下单行约 50 字节（新增 4 个空遥测列各占 1 个逗号）——
    /// 门禁化防止变长回退。
    func testLineWidthStaysCompact() {
        let line = PowerLogEncoding.line(record(offsetSeconds: 123.456, battery: 100, charging: true,
                                                milliWatts: 65432, milliVolts: 65432, milliAmps: 65432,
                                                cpu: 100, memory: 100, systemMilliWatts: 65432))
        XCTAssertLessThanOrEqual(line.utf8.count, 64,
                                 "定点格式单行应保持在 ~50 字节；变长说明精度被意外放开了")
    }
}
