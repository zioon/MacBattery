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
        // 充电状态以 IOPS（IOPSCopyPowerSourcesInfo）官方电源源为准——这与 macOS 系统
        // 菜单栏电池图标的显示完全一致，插上充电器会即时置位，避免 AppleSmartBattery 的
        // IsCharging 固件属性在插入瞬间滞后数秒而误判「不在充电」。
        // IOPS 无数据时才退回 IsCharging 标志或电流方向判定。
        let isCharging: Bool
        if let flag = Self.ioPSIsCharging() {
            isCharging = flag
        } else if props["IsCharging"] != nil {
            isCharging = chargingFlag == 1
        } else {
            isCharging = ampere < 0 && volt > 0
        }

        // 电压/电流（仅用于展示，单位为 V / A）。
        let voltValue = Double(volt) / 1000.0
        guard isCharging else { return (false, 0, voltValue, 0) }

        // 充电时按实际电流计算功率；电流尚未建立（读取为 0）时不强行填功率。
        // 部分机型 Amperage 符号约定可能与常见相反，因此在 isCharging 前提下取绝对值即可。
        let ampereAbs = Double(abs(ampere))
        let watts = (ampere != 0 && volt > 0) ? ampereAbs * Double(volt) / 1_000_000.0 : 0
        let current = ampereAbs / 1000.0
        return (true, watts, voltValue, current)
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
    /// 关键容量值任一不可读（≤0）时返回 nil，表示数据暂不可用。
    static func health() -> BatteryHealth? {
        let service = currentService()
        guard service != 0, let props = readProperties(service) else { return nil }
        let maxCap = intValue(props["AppleRawMaxCapacity"])
        let designCap = intValue(props["DesignCapacity"])
        guard maxCap > 0, designCap > 0 else { return nil }
        return BatteryHealth(
            maxCapacity: maxCap,
            designCapacity: designCap,
            healthPercent: Double(maxCap) / Double(designCap) * 100.0,
            cycleCount: intValue(props["CycleCount"])
        )
    }

    /// 用 IOPS 官方电源源判定是否在充电（与系统菜单栏电池图标一致，插拔即时）。
    private static func ioPSIsCharging() -> Bool? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any],
                let flag = desc[kIOPSIsChargingKey] as? Bool else { continue }
            return flag
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