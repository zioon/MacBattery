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
    static func chargingStatus() -> (isCharging: Bool, watts: Double) {
        let service = currentService()
        guard service != 0, var props = readProperties(service) else { return (false, 0) }

        let ampere = intValue(props["Amperage"])
        let volt = intValue(props["Voltage"])
        let chargingFlag = intValue(props["IsCharging"])

        // 三个关键属性都读不到 → 缓存的句柄可能因休眠失效，重建服务并重试一次。
        if ampere == 0 && volt == 0 && chargingFlag == 0 {
            let rebuilt = rebuildService()
            if rebuilt != 0, let retry = readProperties(rebuilt) {
                props = retry
            }
        }

        // (volt / ampere / chargingFlag 在重试后重新取值)
        let ampereFinal = intValue(props["Amperage"])
        let voltFinal = intValue(props["Voltage"])
        let chargingFlagFinal = intValue(props["IsCharging"])

        // Amperage(mA) 正=放电，负=正在充电；Voltage(mV)。
        // 优先用 IsCharging 状态，其次用电流方向判断。
        let isCharging = voltFinal > 0 && ampereFinal < 0
        let isChargingFlag = chargingFlagFinal == 1

        guard voltFinal > 0, ampereFinal != 0 else { return (isChargingFlag, 0) }
        // 只有真正在充电时按充电功率展示。
        if isCharging || isChargingFlag {
            let watts = Double(abs(ampereFinal)) * Double(voltFinal) / 1_000_000.0
            return (true, watts)
        }
        return (false, 0)
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