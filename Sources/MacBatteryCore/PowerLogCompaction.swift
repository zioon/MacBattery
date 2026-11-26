import Foundation

/// 功率日志的**定点化记录**：CSV 落盘用的整数形态（功率日志的磁盘表示）。
///
/// 背景：原先直接写 Double 的全精度文本，单行约 143 字节，0.5s 一次采样
/// → 约 24.7MB/天、700MB/月，而回填的读取上限只有 48MB，
/// 于是文件长到两天以后历史就永远读不出来了（静默丢历史）。
///
/// 定点化把单行压到约 48 字节（-66%），真正的数量级收益来自 `PowerLogGate`。
///
/// 字段一律取「有界整数」，刻意不用浮点：
/// - 时间用**毫秒**（不是整秒）：整秒会让同秒内的多条记录时间戳相同，
///   而 `mergedByTimestamp` 按时间戳去重 → 回填时静默丢样本。
/// - 功率/电压/电流 ×1000（milli），CPU/内存 ×100（百分数整数）。
public struct PowerSampleRecord: Equatable {

    /// 采样时刻（Unix 毫秒）。毫秒精度保证 0.5s 采样下时间戳互不相同。
    public var epochMilliseconds: Int
    public var batteryPercent: Int
    public var isCharging: Bool
    /// 是否接通外部电源（true = 插着电）。
    ///
    /// `nil` = **未知**：v1 全精度行与升级前的 9 列 v2 行都没有这一列。
    /// 必须与 `isCharging` 分开记：已充满 / 限充时「接了电但不在充电」是常见状态，
    /// 只有 `isCharging` 时它和「正在用电池」无法区分。
    public var externalPower: Bool?
    /// 充电功率 ×1000（W）
    public var chargingMilliWatts: Int
    /// 充电电压 ×1000（V）
    public var chargingMilliVolts: Int
    /// 充电电流 ×1000（A）
    public var chargingMilliAmps: Int
    /// CPU 使用率 0…100（整数百分数；<1% 记为 0，误差 1 个百分点，图表精度足够）
    public var cpuPercent: Int
    /// 内存使用率 0…100
    public var memoryPercent: Int
    /// 估算整机功率 ×1000（W）
    public var systemMilliWatts: Int
    /// 电池温度 ×10（0.1℃ 定点）。`nil` = 未知（旧行 / 机型不提供）。
    ///
    /// 注册表原始读数的量纲随硬件不同，换算见 `BatteryTemperature`；
    /// v1.5.0 最初一律按 0.1℃ 处理，旧落盘值等于注册表原始值（偏大 10 倍），
    /// 读取时由 `BatteryTemperature.repairedDeci` 修正。
    public var temperatureDeciCelsius: Int?
    /// 剩余时间估算（分钟）：-1 = 系统仍在估算，-2 = 接通电源（不限），其余 = 分钟。
    /// `nil` = 未知（旧行）。
    public var remainingMinutes: Int?
    /// 当前电量（mAh，`AppleRawCurrentCapacity`）。`nil` = 未知。
    public var currentCapacityMilliAmpHours: Int?
    /// 是否已充满（`FullyCharged`）。用来区分「已充满」与「接电但未充电（限充）」。
    /// `nil` = 未知（旧行）。
    public var fullyCharged: Bool?

    public init(epochMilliseconds: Int,
                batteryPercent: Int,
                isCharging: Bool,
                chargingMilliWatts: Int,
                chargingMilliVolts: Int,
                chargingMilliAmps: Int,
                cpuPercent: Int,
                memoryPercent: Int,
                systemMilliWatts: Int,
                externalPower: Bool? = nil,
                temperatureDeciCelsius: Int? = nil,
                remainingMinutes: Int? = nil,
                currentCapacityMilliAmpHours: Int? = nil,
                fullyCharged: Bool? = nil) {
        self.epochMilliseconds = epochMilliseconds
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.externalPower = externalPower
        self.chargingMilliWatts = chargingMilliWatts
        self.chargingMilliVolts = chargingMilliVolts
        self.chargingMilliAmps = chargingMilliAmps
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.systemMilliWatts = systemMilliWatts
        self.temperatureDeciCelsius = temperatureDeciCelsius
        self.remainingMinutes = remainingMinutes
        self.currentCapacityMilliAmpHours = currentCapacityMilliAmpHours
        self.fullyCharged = fullyCharged
    }

    /// 从浮点采样定点化。**所有字段夹取到物理上可能的范围**：
    /// 落盘数据会被读回来直接进图表，一个负的 CPU 使用率或 absurd 的功率会画成尖峰。
    public init(t: Date,
                batteryPercent: Int,
                isCharging: Bool,
                chargingWatts: Double,
                chargingVoltage: Double,
                chargingCurrent: Double,
                cpuUsage: Double,
                memoryUsage: Double,
                systemWatts: Double,
                externalPower: Bool? = nil,
                temperatureCelsius: Double? = nil,
                remainingMinutes: Int? = nil,
                currentCapacity: Int? = nil,
                fullyCharged: Bool? = nil) {
        self.epochMilliseconds = Int((t.timeIntervalSince1970 * 1000).rounded())
        self.batteryPercent = min(100, max(0, batteryPercent))
        self.isCharging = isCharging
        self.externalPower = externalPower
        self.chargingMilliWatts = PowerSampleRecord.scaled(chargingWatts)
        self.chargingMilliVolts = PowerSampleRecord.scaled(chargingVoltage)
        self.chargingMilliAmps = PowerSampleRecord.scaled(chargingCurrent)
        self.cpuPercent = PowerSampleRecord.percent(cpuUsage)
        self.memoryPercent = PowerSampleRecord.percent(memoryUsage)
        self.systemMilliWatts = PowerSampleRecord.scaled(systemWatts)
        // 温度：℃ → 0.1℃ 整数。NaN / 无穷视为未知，不写成 0℃。
        self.temperatureDeciCelsius = temperatureCelsius.flatMap { c -> Int? in
            guard c.isFinite else { return nil }
            return Int((c * 10).rounded())
        }
        self.remainingMinutes = remainingMinutes
        // 非正的当前容量是无效读数（0 会被画成「电量耗尽」尖峰）。
        self.currentCapacityMilliAmpHours = currentCapacity.flatMap { c -> Int? in
            guard c > 0 else { return nil }
            return c
        }
        self.fullyCharged = fullyCharged
    }

    /// 采样时刻（由毫秒还原）。
    public var timestamp: Date {
        Date(timeIntervalSince1970: Double(epochMilliseconds) / 1000)
    }

    /// 四舍五入到千分位；负值与 NaN 一律归零。
    private static func scaled(_ v: Double) -> Int {
        guard v.isFinite, v > 0 else { return 0 }
        let scaled = (v * 1000).rounded()
        // 上限只是防溢出，不做物理意义上的钳制（整机功率不会出现 TB 级读数）。
        return scaled >= Double(Int.max) ? Int.max : Int(scaled)
    }

    /// 0…1 的使用率转整数百分数。
    private static func percent(_ v: Double) -> Int {
        guard v.isFinite else { return 0 }
        return min(100, max(0, Int((v * 100).rounded())))
    }
}

/// 功率日志的落盘门控：**变化门控 + 基线兜底**。
///
/// 与 `BatteryHealthLogger` 同一套模式（`lastRecorded` + `baselineInterval`），
/// 保持两个日志的行为一致。
///
/// 语义：
/// - 没有上一条（首条 / 刚重置）→ 写；
/// - 任一字段相对上一条**超出容差** → 写；
/// - 都在容差内 → 只在距上一条已落盘记录超过 `baselineInterval` 时写一条，
///   否则丢弃。这样即使数值完全平直，历史里也仍有按时间分散的点。
public struct PowerLogGate: Equatable {

    /// 充电功率容差（milliW）：0.5W。低于此变化视为噪声。
    public var milliWattTolerance: Int
    /// 充电电压容差（milliV）：0.1V。
    public var milliVoltTolerance: Int
    /// 充电电流容差（milliA）：0.1A。
    public var milliAmpTolerance: Int
    /// 整机功率容差（milliW）：2W。整机功率是**估算值**，本身抖动就有 1W 量级，
    /// 容差给太小会让这条判据形同虚设（等于全量落盘）。
    public var systemMilliWattTolerance: Int
    /// CPU / 内存容差（百分点）：2。
    public var percentTolerance: Int
    /// 电池温度容差（0.1℃）：10，即 1℃。温度变化慢，1℃ 以内视为噪声。
    public var temperatureTolerance: Int
    /// 基线兜底间隔（秒）：即使全在容差内，也至少每 60s 留一条。
    public var baselineInterval: TimeInterval

    public init(milliWattTolerance: Int,
                milliVoltTolerance: Int,
                milliAmpTolerance: Int,
                systemMilliWattTolerance: Int,
                percentTolerance: Int,
                temperatureTolerance: Int,
                baselineInterval: TimeInterval) {
        self.milliWattTolerance = milliWattTolerance
        self.milliVoltTolerance = milliVoltTolerance
        self.milliAmpTolerance = milliAmpTolerance
        self.systemMilliWattTolerance = systemMilliWattTolerance
        self.percentTolerance = percentTolerance
        self.temperatureTolerance = temperatureTolerance
        self.baselineInterval = baselineInterval
    }

    /// 默认取值。
    ///
    /// 稳态（不充电、电量不变、负载平稳）下写入率降到 **1/60s**：
    /// 约 1440 条/天 ≈ 66KB/天。繁忙时接近全量（见 CHANGELOG 的已知边界）。
    public static let `default` = PowerLogGate(
        milliWattTolerance: 500,
        milliVoltTolerance: 100,
        milliAmpTolerance: 100,
        systemMilliWattTolerance: 2000,
        percentTolerance: 2,
        temperatureTolerance: 10,
        baselineInterval: 60
    )

    /// 判断本次采样是否需要落盘。
    /// - Parameters:
    ///   - previous: 上一条**已落盘**的记录（不是上一条采样 —— 采样是 0.5s 一条，
    ///     落盘可能隔了几十条，未落盘的采样不能用来判断「是否变化」）。
    ///   - current: 本次采样。
    public func shouldPersist(previous: PowerSampleRecord?, current: PowerSampleRecord) -> Bool {
        guard let p = previous else { return true }
        if p.batteryPercent != current.batteryPercent { return true }
        if p.isCharging != current.isCharging { return true }
        // 插拔电源必须留痕：否则图表上「充电 / 接电」时段带的边界会被基线间隔拉偏 60s。
        if p.externalPower != current.externalPower { return true }
        if abs(p.chargingMilliWatts - current.chargingMilliWatts) >= milliWattTolerance { return true }
        if abs(p.chargingMilliVolts - current.chargingMilliVolts) >= milliVoltTolerance { return true }
        if abs(p.chargingMilliAmps - current.chargingMilliAmps) >= milliAmpTolerance { return true }
        if abs(p.systemMilliWatts - current.systemMilliWatts) >= systemMilliWattTolerance { return true }
        if abs(p.cpuPercent - current.cpuPercent) >= percentTolerance { return true }
        if abs(p.memoryPercent - current.memoryPercent) >= percentTolerance { return true }
        // 温度跨越 1℃ 必须留痕：否则温升曲线只能靠 60s 基线，尖锐的发热段会被削平。
        if let a = p.temperatureDeciCelsius, let b = current.temperatureDeciCelsius,
           abs(a - b) >= temperatureTolerance { return true }
        // 充满状态翻转（已充满 ↔ 未充满）是充电器行为的关键边界，必须立即记录。
        if p.fullyCharged != current.fullyCharged { return true }

        // 全部在容差内 → 靠基线间隔兜底。
        let elapsedMillis = current.epochMilliseconds - p.epochMilliseconds
        if elapsedMillis < 0 {
            // 时钟回拨（NTP 校正 / 用户改时区）：差值为负会让基线判据永远不成立，
            // 之后再也不写任何兜底记录。强制写一条把基准拉回当前时间。
            return true
        }
        return Double(elapsedMillis) / 1000 >= baselineInterval
    }
}

/// 功率日志的文本编解码（定点格式）。
///
/// ⚠️ **格式版本靠文件名区分，不靠行内标记**：旧的 Double 格式与新的定点格式
/// 列数相同，逐列启发式判断是有歧义的（例如旧格式里恰好写成 `12` 的整数瓦数
/// 会被当成 12 milliW = 0.012W，静默错一个数量级）。
/// 因此 v2 写入 `power_log_v2.csv`，v1 仍是 `power_log.csv`，读取时两个都读再合并 ——
/// 见 `PowerLogStore.readRecentHistory`。
public enum PowerLogEncoding {

    /// v2 表头（列语义与 v1 不同，文件名也不同）。
    ///
    /// 第 10–14 列是**后加**的：早期 v2 行只有前 9 列，随后增加到 10 列（外电），
    /// 现在为 14 列（温度 / 剩余时间 / 当前容量 / 是否充满）。解析时接受 9–14 列
    /// （见 `parseV2`）。列数不同即可无歧义区分新旧行，因此不需要再换文件名。
    /// 注意：已存在的文件不会重写表头（追加写），旧表头留在文件首行不影响解析。
    public static let headerV2 =
        "epochMillis,batteryPercent,isCharging,chargingMilliWatts,chargingMilliVolts,"
        + "chargingMilliAmps,cpuPercent,memoryPercent,systemMilliWatts,externalPower,"
        + "temperatureDeciCelsius,remainingMinutes,currentCapacityMilliAmpHours,fullyCharged\n"

    /// v1 表头（保留用于识别 v1 文件头行）。
    public static let headerV1 =
        "epoch,batteryPercent,isCharging,chargingWatts,chargingVoltage,chargingCurrent,"
        + "cpuUsage,memoryUsage,systemWatts\n"

    /// 序列化为一行（含换行符）。
    ///
    /// `externalPower`：1 / 0 = 接电 / 未接电，-1 = 未知（仅在把旧记录原样写回时出现）。
    /// 后加的 4 列用**空串**表示未知：`remainingMinutes` 的 -1 / -2 是有效值
    ///（估算中 / 接通电源），不能拿 -1 兼任「未知」。
    public static func line(_ r: PowerSampleRecord) -> String {
        let external: String
        switch r.externalPower {
        case .some(true): external = "1"
        case .some(false): external = "0"
        case .none: external = "-1"
        }
        let temperature = r.temperatureDeciCelsius.map { String($0) } ?? ""
        let remaining = r.remainingMinutes.map { String($0) } ?? ""
        let capacity = r.currentCapacityMilliAmpHours.map { String($0) } ?? ""
        let fully: String
        switch r.fullyCharged {
        case .some(true): fully = "1"
        case .some(false): fully = "0"
        case .none: fully = ""
        }
        return "\(r.epochMilliseconds),\(r.batteryPercent),\(r.isCharging ? 1 : 0),"
            + "\(r.chargingMilliWatts),\(r.chargingMilliVolts),\(r.chargingMilliAmps),"
            + "\(r.cpuPercent),\(r.memoryPercent),\(r.systemMilliWatts),\(external),"
            + "\(temperature),\(remaining),\(capacity),\(fully)\n"
    }

    /// 解析一行 v2 文本。
    ///
    /// 全部列必须是**合法整数**—— 这是刻意的：定点格式里出现小数点/指数说明该行
    /// 不是 v2 数据，宁可丢弃也不能猜（猜错就是错数量级的历史）。
    /// 表头行与早于 2000 年的时间戳都会在这里被拒掉。
    ///
    /// 兼容 **9–14 列**：9 列（升级前无外电）、10 列（+外电）、11–14 列
    ///（+温度 / 剩余时间 / 当前容量 / 是否充满）。缺失的尾列一律读成 `nil`（未知），
    /// 绝不默认成 0 / false —— 否则「旧数据未记录」会被图表画成 0℃ / 用电池。
    /// 后加列允许空串（同样表示未知），但非空时必须是合法整数。
    /// 温度列还会经 `BatteryTemperature.repairedDeci` 还原 v1.5.0 早期的原始量纲错值。
    public static func parseV2(_ line: Substring) -> PowerSampleRecord? {
        let parts = line.split(separator: ",", omittingEmptySubsequences: false)
        guard (9...14).contains(parts.count),
              let epoch = Int(parts[0]),
              let battery = Int(parts[1]),
              let charging = Int(parts[2]),
              let milliWatts = Int(parts[3]),
              let milliVolts = Int(parts[4]),
              let milliAmps = Int(parts[5]),
              let cpu = Int(parts[6]),
              let memory = Int(parts[7]),
              let systemWatts = Int(parts[8])
        else { return nil }
        // 2000-01-01 = 946684800 秒 = 946684800000 毫秒。早于此即无效行 / 表头。
        guard epoch >= 946_684_800_000 else { return nil }
        // 外电状态：1 / 0 为明确值；-1 或整列缺失 = 未知（**不能**默认成 false，
        // 否则「旧数据未记录」会被图表画成「用电池」）。
        var externalPower: Bool?
        if parts.count >= 10 {
            guard let raw = Int(parts[9]) else { return nil }
            externalPower = raw == 1 ? true : (raw == 0 ? false : nil)
        }
        // 可选整数列：缺失或空串 = 未知；非空但不是整数 → 整行作废。
        func optionalInt(_ index: Int) -> (ok: Bool, value: Int?) {
            guard parts.count > index else { return (true, nil) }
            let s = parts[index]
            if s.isEmpty { return (true, nil) }
            guard let v = Int(s) else { return (false, nil) }
            return (true, v)
        }
        let temperature = optionalInt(10)
        let remaining = optionalInt(11)
        let capacity = optionalInt(12)
        guard temperature.ok, remaining.ok, capacity.ok else { return nil }
        var fullyCharged: Bool?
        if parts.count >= 14, !parts[13].isEmpty {
            guard let raw = Int(parts[13]) else { return nil }
            fullyCharged = raw == 1 ? true : (raw == 0 ? false : nil)
        }
        return PowerSampleRecord(epochMilliseconds: epoch,
                                 batteryPercent: min(100, max(0, battery)),
                                 isCharging: charging == 1,
                                 chargingMilliWatts: max(0, milliWatts),
                                 chargingMilliVolts: max(0, milliVolts),
                                 chargingMilliAmps: max(0, milliAmps),
                                 cpuPercent: min(100, max(0, cpu)),
                                 memoryPercent: min(100, max(0, memory)),
                                 systemMilliWatts: max(0, systemWatts),
                                 externalPower: externalPower,
                                 temperatureDeciCelsius: temperature.value
                                     .flatMap { BatteryTemperature.repairedDeci($0) },
                                 remainingMinutes: remaining.value,
                                 currentCapacityMilliAmpHours: capacity.value.map { max(0, $0) },
                                 fullyCharged: fullyCharged)
    }

    /// 解析一行 v1（全精度 Double）文本为定点记录。仅用于读取历史 v1 文件。
    public static func parseV1(_ line: Substring) -> PowerSampleRecord? {
        let parts = line.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 9,
              let epochSeconds = Double(parts[0]), epochSeconds >= 946_684_800
        else { return nil }
        // ⚠️ 时间戳必须**整段**解析，不能只取小数点前的整数部分：
        // v1 写的是 0.5s 间隔的带小数 epoch，下取整到整秒会让同一秒内的两条样本
        // 拿到相同时间戳，回填去重时又丢一半历史（0.5s 采样 → 每秒丢 1 条）。
        // 旧实现（`split(".").first`）正是这个错误，2026-10-17 由新单测抓出。
        return PowerSampleRecord(t: Date(timeIntervalSince1970: epochSeconds),
                                 batteryPercent: Int(parts[1]) ?? 0,
                                 isCharging: (parts[2] == "1"),
                                 chargingWatts: Double(parts[3]) ?? 0,
                                 chargingVoltage: Double(parts[4]) ?? 0,
                                 chargingCurrent: Double(parts[5]) ?? 0,
                                 cpuUsage: Double(parts[6]) ?? 0,
                                 memoryUsage: Double(parts[7]) ?? 0,
                                 systemWatts: Double(parts[8]) ?? 0)
    }
}
