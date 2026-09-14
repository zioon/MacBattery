import Foundation
import IOKit
import SMCBridge

/// 通过 AppleSMC 读取硬件传感器（复用经验证的 C 实现，保证 80 字节协议帧布局）。
/// 整机功耗键在 Intel 机型上因固件/权限而异，这里逐个探测候选键，取首个非零值。
/// 连接只在首次打开后复用，避免高频采样时反复 open/close；且只在第一次探测哪个键有效。
/// 注意：本枚举只在后台串行采样队列中被调用，因此静态缓存无需额外加锁。
enum SMCReader {

    /// 系统整机功率的候选 SMC 键。
    private static let powerKeys = [
        "PSTR", // System total power (W)
        "PDTR", // 一些固件的总功耗
        "PCHC", // Chip/package power
        "PSYS", // 部分固件
        "PWRS",
    ]

    /// 复用的 SMC 连接（0 表示未打开）。
    private static var conn: io_connect_t = 0
    /// 首次探测出的有效功率键（后续固定读它，不再遍历候选）。
    private static var effectiveKey: String?

    /// 返回整机功率（瓦特）。读不到或返回 0 时返回 0（上层回退为估算）。
    static func systemWatts() -> Double {
        if conn == 0 { conn = SMCOpen() }
        guard conn != 0 else { return 0 }

        // 首次探测：确定本机可读的功率键。
        if effectiveKey == nil {
            for key in powerKeys {
                let value = SMCGetFloatValue(conn, key)
                if value > 0, value.isFinite {
                    effectiveKey = key
                    break
                }
            }
            // 一个键都读不到 → 本机型不支持整机功率，回退估算。
            if effectiveKey == nil { return 0 }
        }

        let value = SMCGetFloatValue(conn, effectiveKey!)
        if value > 0, value.isFinite { return value }

        // 已确定过的有效键读到 0 → 连接可能因休眠失效，重建一次并重读。
        SMCClose(conn)
        conn = SMCOpen()
        guard conn != 0 else {
            effectiveKey = nil
            return 0
        }
        return SMCGetFloatValue(conn, effectiveKey!)
    }
}