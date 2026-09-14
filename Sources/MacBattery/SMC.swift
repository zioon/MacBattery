import Foundation
import SMCBridge

/// 通过 AppleSMC 读取硬件传感器（复用经验证的 C 实现，保证 80 字节协议帧布局）。
/// 整机功耗键在 Intel 机型上因固件/权限而异，这里逐个探测候选键，取首个非零值。
enum SMCReader {

    /// 系统整机功率的候选 SMC 键。
    private static let powerKeys = [
        "PSTR", // System total power (W)
        "PDTR", // 一些固件的总功耗
        "PCHC", // Chip/package power
        "PSYS", // 部分固件
        "PWRS",
    ]

    /// 返回整机功率（瓦特）。读不到或返回 0 时返回 0（上层回退为估算）。
    static func systemWatts() -> Double {
        let conn = SMCOpen()
        guard conn != 0 else { return 0 }
        defer { SMCClose(conn) }

        for key in powerKeys {
            let value = SMCGetFloatValue(conn, key)
            if value > 0, value.isFinite {
                return value
            }
        }
        return 0
    }
}