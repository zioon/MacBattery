import Foundation
import IOKit
import IOKit.ps

/// 电池信息读取。全部采用 macOS 官方公开 API，无需 root 权限。
/// 注册表读取仅在后台串行采样队列中调用，缓存的 service 句柄无需额外加锁。
enum BatteryReader {

    /// 缓存的 AppleSmartBattery 服务句柄（0 表示尚未匹配）。复用避免高频反复匹配/释放。
    private static var cachedService: io_service_t = 0

    /// 当前电量百分比（0...100）
    static func level() -> Int {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return 0 }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return 0 }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any] else { continue }
            guard let capacity = desc[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = desc[kIOPSMaxCapacityKey] as? Int,
                  maxCapacity > 0 else { continue }
            return Int((Double(capacity) / Double(maxCapacity) * 100.0).rounded())
        }
        return 0
    }

    /// 当前充电功率（瓦特）与是否正在充电。
    ///
    /// 通过 AppleSmartBattery 的 `Voltage`(mV) × `Amperage`(mA) 计算。
    /// `Amperage` 为负时表示电流正在充入电池，取绝对值即为充电功率。
    static func chargingStatus() -> (isCharging: Bool, watts: Double, voltage: Double, current: Double) {
        let service = currentService()
        guard service != 0, var props = readProperties(service) else { return (false, 0, 0, 0) }

        var ampere = intValue(props["Amperage"])
        var volt = intValue(props["Voltage"])
        var chargingFlag = intValue(props["IsCharging"])

        // 三个关键属性都读不到 → 缓存的句柄可能因休眠失效，重建服务并重试一次。
        if ampere == 0 && volt == 0 && chargingFlag == 0 {
            let rebuilt = rebuildService()
            if rebuilt != 0, let retry = readProperties(rebuilt) {
                props = retry
                ampere = intValue(retry["Amperage"])
                volt = intValue(retry["Voltage"])
                chargingFlag = intValue(retry["IsCharging"])
            }
        }

        // Amperage(mA) 负=充入、正=放电；Voltage(mV)。
        // 充电状态判定与 MacMonitor 完全一致：以 `pmset -g batt` 为权威
        // （charging = 含 "charging" 且不含 "discharging"，与系统菜单栏同源）。
        // pmset 调用失败（进程无法启动）时退回 IOPS / IsCharging 标志 / 电流方向综合判定。
        let isCharging: Bool
        if let pmset = Self.pmsetBatteryStatus() {
            isCharging = pmset.charging
        } else {
            isCharging = (Self.ioPSIsCharging() ?? (chargingFlag == 1)) || (ampere < 0 && volt > 0)
        }

        // 电压/电流/功率与充电状态的关系：
        // - 电压/电流恒返回读数（mV/mA 转 V/A）；
        // - 充电功率严格跟随 isCharging：pmset 权威判定为充电时才有功率。
        //   ampere<0 的电流方向兜底只在 pmset 不可用分支里已纳入 isCharging，
        //   这里不再叠加，避免部分机型 Amperage 符号约定相反（放电也为负）被误当充电。
        let voltValue = Double(volt) / 1000.0
        let ampereAbs = Double(abs(ampere))
        let watts = (isCharging && volt > 0 && ampere != 0)
            ? ampereAbs * Double(volt) / 1_000_000.0
            : 0
        return (isCharging, watts, voltValue, ampereAbs / 1000.0)
    }

    /// 电池健康信息（变化缓慢，供健康图表按需读取）。
    struct BatteryHealth {
        /// 当前最大容量（mAh，AppleRawMaxCapacity）
        var maxCapacity: Int
        /// 设计容量（mAh，DesignCapacity）
        var designCapacity: Int
        /// 电池健康度（% = 当前最大容量 / 设计容量）
        var healthPercent: Double
        /// 充放电循环次数（CycleCount）
        var cycleCount: Int
    }

    /// 读取电池健康信息（当前最大容量 / 设计容量 / 健康度 / 循环次数）。
    /// 部分机型 AppleSmartBattery 的容量键可能有缺省（如 `DesignCapacity` 为 0），
    /// 因此只要「当前最大容量」可读就返回记录；健康度仅在设计容量可读时计算，否则记为 0。
    static func health() -> BatteryHealth? {
        let service = currentService()
        guard service != 0, let props = readProperties(service) else { return nil }
        // 当前最大容量：优先 AppleRawMaxCapacity，缺省时退回 MaxCapacity。
        let maxCap = firstPositive(intValue(props["AppleRawMaxCapacity"]),
                                   intValue(props["MaxCapacity"]))
        guard maxCap > 0 else { return nil }
        // 设计容量：优先 DesignCapacity，缺省时退回 MaxCapacity（作为粗略退路）。
        let designCap = firstPositive(intValue(props["DesignCapacity"]),
                                      intValue(props["MaxCapacity"]))
        let health: Double = designCap > 0
            ? Double(maxCap) / Double(designCap) * 100.0
            : 0
        return BatteryHealth(
            maxCapacity: maxCap,
            designCapacity: designCap,
            healthPercent: health,
            cycleCount: intValue(props["CycleCount"])
        )
    }

    /// 返回第一个 >0 的值；全部 ≤0 时返回 0。
    private static func firstPositive(_ a: Int, _ b: Int) -> Int {
        if a > 0 { return a }
        return b > 0 ? b : 0
    }

    /// 用 `pmset -g batt` 判定电池状态，解析规则与 MacMonitor 的 fetchBattery 完全一致：
    /// - onAC      = 输出含 "AC Power"（插着电源）
    /// - charging  = 含 "charging" 且不含 "discharging"（正在充电）
    /// - charged   = 含 "charged" 或 "finishing charge"（已充满 / 收尾充电）
    /// pmset 与系统菜单栏电池图标同源；2 秒内复用上次结果，避免每 0.5s 采样拉起进程。
    /// 仅在后台串行采样队列调用，静态缓存无需加锁。进程启动失败时返回 nil。
    private static var pmsetCacheTime: TimeInterval = 0
    private static var pmsetCache: (onAC: Bool, charging: Bool, charged: Bool)?

    private static func pmsetBatteryStatus() -> (onAC: Bool, charging: Bool, charged: Bool)? {
        let now = Date().timeIntervalSinceReferenceDate
        if let cached = pmsetCache, now - pmsetCacheTime < 2.0 { return cached }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8) else { return nil }
        let status = (
            onAC: output.contains("AC Power"),
            charging: output.contains("charging") && !output.contains("discharging"),
            charged: output.contains("charged") || output.contains("finishing charge")
        )
        pmsetCache = status
        pmsetCacheTime = now
        return status
    }

    /// 用 IOPS 官方电源源判定是否在充电（与系统菜单栏电池图标一致，插拔即时）。
    /// 兼容 CFBoolean（桥接为 Bool）与 CFNumber（0/1）两种取值形式。
    private static func ioPSIsCharging() -> Bool? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any],
                let value = desc[kIOPSIsChargingKey] else { continue }
            if let flag = value as? Bool { return flag }
            if let n = value as? NSNumber { return n.boolValue }
        }
        return nil
    }

    /// 读取 AppleSmartBattery 的完整属性字典；失败返回 nil（调用方据此重建句柄重试）。
    private static func readProperties(_ service: io_service_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
            == kIOReturnSuccess,
            let dict = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// 获取缓存的 AppleSmartBattery 服务句柄；首次调用时匹配一次并复用。
    private static func currentService() -> io_service_t {
        if cachedService == 0 {
            cachedService = IOServiceGetMatchingService(kIOMainPortDefault,
                                                        IOServiceMatching("AppleSmartBattery"))
        }
        return cachedService
    }

    /// 释放无效句柄并重新匹配，返回新句柄（失败为 0）。
    private static func rebuildService() -> io_service_t {
        if cachedService != 0 { IOObjectRelease(cachedService); cachedService = 0 }
        cachedService = IOServiceGetMatchingService(kIOMainPortDefault,
                                                    IOServiceMatching("AppleSmartBattery"))
        return cachedService
    }

    /// 从注册表属性字典中尽量提取 Int（兼容 CFNumber 与 CFString 两种表示）。
    private static func intValue(_ value: Any?) -> Int {
        guard let value else { return 0 }
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }
}