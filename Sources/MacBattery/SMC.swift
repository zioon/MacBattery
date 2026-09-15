import Foundation
import IOKit
import SMCBridge

/// 通过 AppleSMC 读取硬件传感器（复用经验证的 C 实现，保证 80 字节协议帧布局）。
/// 整机功耗键在 Intel 机型上因固件/权限而异，这里逐个探测候选键，取首个非零值。
/// 连接只在首次打开后复用，避免高频采样时反复 open/close；且只在第一次探测哪个键有效。
/// 本枚举既会被后台串行采样队列调用，也会被主线程入口（首拍采样 / 电源事件补采样）调用，
/// 因此静态缓存（conn / effectiveKey）统一由 `lock` 保护。
enum SMCReader {

    /// 保护静态状态 `conn` / `effectiveKey` 的锁。
    /// 用 `NSRecursiveLock`（而非 `NSLock`）以容忍同类型内的嵌套调用；目标 macOS 12，
    /// 不使用 macOS 13+ 的 `OSAllocatedUnfairLock`。
    private static let lock = NSRecursiveLock()

    /// 系统整机功率的候选 SMC 键，从 SMCBridge 的唯一定义处（SMCPowerKeys）读取。
    /// 顺序即探测优先级：逐个探测，取首个读到非零值的键。
    private static let powerKeys: [String] = {
        var keys: [String] = []
        let count = SMCPowerKeyCount()          // Int32
        for i in 0..<count {
            if let cStr = SMCPowerKey(i) {      // UnsafePointer<CChar>?
                keys.append(String(cString: cStr))
            }
        }
        return keys
    }()

    /// 复用的 SMC 连接（0 表示未打开）。
    private static var conn: io_connect_t = 0
    /// 首次探测出的有效功率键（后续固定读它，不再遍历候选）。
    private static var effectiveKey: String?

    /// 返回整机功率（瓦特）。读不到或返回 0 时返回 0（上层回退为估算）。
    static func systemWatts() -> Double {
        // 保护静态状态 `conn` 与 `effectiveKey`：函数体只有 SMC 的 C 调用
        //（SMCOpen / SMCClose / SMCGetFloatValue），没有子进程、也不调用其他被锁类型，
        // 因此可安全地整体持锁。
        lock.lock()
        defer { lock.unlock() }

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