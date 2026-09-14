import Foundation
import IOKit
import IOKit.ps

/// 电池信息读取。全部采用 macOS 官方公开 API，无需 root 权限。
enum BatteryReader {

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

    /// 当前充电功率（瓦特）。通过 AppleSmartBattery 的 电压 x 电流 计算。
    /// Amperage 单位为 mA，负号表示正在充电（相对放电方向）。返回绝对值，单位 W。
    static func chargingWatts() -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
            == kIOReturnSuccess,
            let props = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return 0
        }

        // 注意：Amperage 和 Voltage 在部分机型上以字符串形式暴露，这里做兼容转换。
        let ampere = intValue(props["Amperage"])     // mA
        let volt = intValue(props["Voltage"])        // mV
        guard ampere != 0, volt != 0 else { return 0 }

        // 只有电流为负（即真正在充电）时才按充电功率展示，否则返回 0。
        guard ampere < 0 else { return 0 }
        let watts = Double(abs(ampere)) * Double(volt) / 1_000_000.0
        return watts
    }

    /// 从注册表属性中尽量提取 Int（兼容 CFNumber 与 CFString 两种表示）。
    private static func intValue(_ value: Any?) -> Int {
        guard let value else { return 0 }
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }
}