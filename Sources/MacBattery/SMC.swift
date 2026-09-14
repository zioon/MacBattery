import Foundation
import IOKit

/// 通过 AppleSMC 读取硬件传感器。整机功耗键在 Intel 机型上因固件而异，
/// 这里通过探测一组候选键（flt 类型、4 字节）来自动找到可读的功耗值。
enum SMCReader {

    /// 系统整机功率的候选 SMC 键（Intel 常见）。
    /// 不同固件暴露的键不同，逐个探测取首个非零值。
    private static let powerKeys = [
        "PSTR", // System total power (W) - 部分机型
        "PDTR", // 一些固件的总功耗
        "PCHC", // Package/Chip power（部分机型）
        "PWRS", // 部分固件
        "EDR0", // 部分架构
    ]

    /// 返回整机功率（瓦特）。读不到或返回 0 时返回 0（UI 层显示为 "--"）。
    static func systemWatts() -> Double {
        guard let client = try? SMCClient() else { return 0 }
        for key in powerKeys {
            if let value = try? client.readFloat(key), value > 0, value.isFinite {
                return Double(value)
            }
        }
        return 0
    }
}

// MARK: - SMCClient（精简实现）

/// 极简 AppleSMC 客户端：打开连接 + 按键名读取 float 数值。
private class SMCClient {

    enum SMCError: Error {
        case serviceNotFound
        case openFailed
    }

    // 协议常量
    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCGetKeyInfo: UInt8 = 9
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCKeyNotFound: UInt32 = 0x84  // 键不存在

    private var connection: io_connect_t = 0

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed }
        connection = conn
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    /// 读取 4 字节 float 型键值。
    func readFloat(_ key: String) throws -> Float {
        let data = try readKey(key)
        guard data.count >= MemoryLayout<Float>.size else { throw SMCError.serviceNotFound }
        return data.withUnsafeBytes { $0.load(as: Float.self) }
    }

    /// 发送一次 SMC 调用封装（80 字节 SMCParamStruct）。
    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        let kr = IOConnectCallStructMethod(
            connection,
            UInt32(SMCClient.kSMCHandleYPCEvent),
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            MemoryLayout<SMCParamStruct>.size
        )
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed }
        return output
    }

    /// 按 4 字符键名读取原始数据。
    private func readKey(_ key: String) throws -> [UInt8] {
        let fourCC = fourCharCode(key)
        return try readKey(fourCC)
    }

    private func readKey(_ key: FourCharCode) throws -> [UInt8] {
        // 先查询键信息以获得数据大小
        var infoStruct = SMCParamStruct()
        infoStruct.data8 = SMCClient.kSMCGetKeyInfo
        infoStruct.key = key

        let info = try call(&infoStruct)
        guard info.result != SMCClient.kSMCKeyNotFound else { throw SMCError.serviceNotFound }

        var readStruct = SMCParamStruct()
        readStruct.data8 = SMCClient.kSMCReadKey
        readStruct.key = key
        readStruct.dataSize = info.dataSize

        let output = try call(&readStruct)
        guard output.result == 0 else { throw SMCError.serviceNotFound }
        return Array(output.bytes.prefix(Int(output.dataSize)))
    }

    private func fourCharCode(_ string: String) -> FourCharCode {
        let chars = Array(string.utf8).prefix(4)
        var code: FourCharCode = 0
        for c in chars {
            code = (code << 8) | FourCharCode(c)
        }
        return code
    }
}

// MARK: - SMCParamStruct（80 字节协议帧）

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes = [UInt8](repeating: 0, count: 32)
}

// 下面三个结构体拼成 SMCParamStruct 的标准 80 字节布局。
struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}