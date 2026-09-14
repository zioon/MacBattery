import Foundation
import IOKit
import IOKit.ps

/// 电池信息读取。全部采用 macOS 官方公开 API，无需 root 权限。
/// 注册表读取仅在后台串行采样队列中调用，缓存的 service 句柄无需额外加锁。
enum BatteryReader {

    /// 缓存的 AppleSmartBattery 服务句柄（0 表示尚未匹配）。复用避免高频反复匹配/释放。
    private static var batteryService: io_service_t = 0

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
        var service = batteryService()
        guard service != 0 else { return (false, 0) }

        var ampere = registryInt(service, "Amperage") ?? 0
        var volt = registryInt(service, "Voltage") ?? 0
        var chargingFlag = registryInt(service, "IsCharging") ?? 0

        // 三个关键属性都读不到 → 缓存的句柄可能因休眠失效，重建服务并重试一次。
        if ampere == 0 && volt == 0 && chargingFlag == 0 {
            let rebuilt = rebuildBatteryService()
            if rebuilt != 0 {
                service = rebuilt
                ampere = registryInt(service, "Amperage") ?? 0
                volt = registryInt(service, "Voltage") ?? 0
                chargingFlag = registryInt(service, "IsCharging") ?? 0
            }
        }

        // Amperage(mA) 正=放电，负=正在充电；Voltage(mV)。
        // 优先用 IsCharging 状态，其次用电流方向判断。
        let isCharging = volt > 0 && ampere < 0
        let isChargingFlag = chargingFlag == 1

        guard volt > 0, ampere != 0 else { return (isChargingFlag, 0) }
        // 只有真正在充电时按充电功率展示。
        if isCharging || isChargingFlag {
            let watts = Double(abs(ampere)) * Double(volt) / 1_000_000.0
            return (true, watts)
        }
        return (false, 0)
    }

    /// 获取缓存的 AppleSmartBattery 服务句柄；首次调用时匹配一次并复用。
    private static func batteryService() -> io_service_t {
        if batteryService == 0 {
            batteryService = IOServiceGetMatchingService(kIOMainPortDefault,
                                                         IOServiceMatching("AppleSmartBattery"))
        }
        return batteryService
    }

    /// 释放无效句柄并重新匹配，返回新句柄（失败为 0）。
    private static func rebuildBatteryService() -> io_service_t {
        if batteryService != 0 { IOObjectRelease(batteryService); batteryService = 0 }
        batteryService = IOServiceGetMatchingService(kIOMainPortDefault,
                                                     IOServiceMatching("AppleSmartBattery"))
        return batteryService
    }

    /// 读取 IORegistry 服务上单个数值属性（兼容 CFNumber 与 CFString 两种表示）。
    /// 相比 IORegistryEntryCreateCFProperties 的整字典复制，按 key 读取更快更省。
    private static func registryInt(_ service: io_service_t, _ key: String) -> Int? {
        guard let unmanaged = IORegistryEntryCreateProperty(service, key as CFString,
                                                            kCFAllocatorDefault, 0)
        else { return nil }
        let prop = unmanaged.takeRetainedValue()
        if let n = prop as? NSNumber { return n.intValue }
        if let s = prop as? String { return Int(s) }
        return nil
    }
}