import Foundation

/// App ↔ root helper 的指令/回执协议与落盘位置（**唯一定义处**）。
///
/// 两个进程各写一半（App 写指令文件、helper 写回执文件）。字段名一旦不一致，就是
/// 「编译能过、运行时静默失效」的缺陷 —— 而且 symptom 只是「开关点了没反应」，
/// 极难定位。所以双方都从本类型取定义，不允许各自手写一份 JSON 字面量。
///
/// 顺带说明为什么不用 XPC / 授权插件：本项目不签名（ad-hoc）、不上架，XPC 的
/// 授权校验需要用户点系统弹窗并依赖签名标识；而根守护 + 文件信箱的形态与现有
/// `macbattery_power.json` 完全一致，用户只需一次性 `sudo install_helper.sh`。
public enum ChargeLimitWire {

    /// 协议版本：字段或语义发生**不兼容**变更时必须递增。
    ///
    /// App 与 helper 是分开发布的（helper 要用户 `sudo` 重装），版本错配是常态：
    /// 用户升级了 App 却没重装 helper。回执里带上版本号，App 发现不一致就提示
    /// 「helper 版本过旧，请重新安装」，而不是按错位的字段去解读。
    public static let version = 1

    /// 下发给 helper 的动作。
    ///
    /// 刻意只有两个取值：`/tmp` 是全局可写的，任何本地用户都能伪造指令文件。
    /// 把动作收敛成白名单枚举（配合 helper 侧的键/值白名单），最坏后果就被限制在
    /// 「切换充电抑制」，不会变成任意 SMC 写入的提权面。
    public enum Action: String, Codable {
        /// 禁止充电（写抑制值）。
        case inhibit
        /// 允许充电（写允许值）。
        case allow
    }

    /// App → helper 的指令。
    public struct Command: Codable, Equatable {
        public var proto: Int
        public var action: Action
        /// 下发时的上限（%）。仅供 helper 记录/排查，不参与执行判定。
        public var limit: Int
        /// 下发时间（Unix epoch 秒）。helper 靠它判断指令是否仍然「新鲜」。
        public var timestamp: Double

        public init(action: Action, limit: Int, timestamp: Double) {
            self.proto = ChargeLimitWire.version
            self.action = action
            self.limit = limit
            self.timestamp = timestamp
        }
    }

    /// helper → App 的回执。
    public struct Status: Codable, Equatable {
        public var proto: Int
        /// 本机是否存在**可安全写入**的充电抑制键。false = 本机不支持，功能无法执行。
        public var supported: Bool
        /// helper 当前**实际**施加的状态（写完做了读回校验后才置位）。
        public var inhibited: Bool
        /// 实际用到的 SMC 键名（排查用；跳过/不认识的键不会出现在这里）。
        public var keys: [String]
        /// 回执时间（Unix epoch 秒）。App 靠它判断 helper 是否还在运行。
        public var timestamp: Double
        /// 失败原因**代码**（如 `no_charge_key` / `write_failed`）。
        /// 刻意用代码而不是文案：文案由 App 侧本地化，helper 不参与多语言。
        public var error: String?

        public init(proto: Int,
                    supported: Bool,
                    inhibited: Bool,
                    keys: [String],
                    timestamp: Double,
                    error: String?) {
            self.proto = proto
            self.supported = supported
            self.inhibited = inhibited
            self.keys = keys
            self.timestamp = timestamp
            self.error = error
        }
    }

    /// 指令文件（App 写、helper 读）。
    public static let commandPath = "/tmp/macbattery_charge_cmd.json"

    /// 回执文件（helper 写、App 读）。
    public static let statusPath = "/tmp/macbattery_charge_status.json"

    /// 指令新鲜度窗口（秒）：超过它即视为「App 已退出」，helper 复位为「允许充电」。
    ///
    /// 这是**故障安全**设计：不能让「App 已经不在运行」变成「充电被永久禁止」——
    /// 否则用户关掉挂件后就再也没法把电充满，而解除手段（重装 helper / SMC 复位）
    /// 不是普通用户能自己想到的。
    public static let commandFreshness: TimeInterval = 30

    /// App 刷新指令的心跳间隔（秒）。
    /// 取新鲜度窗口的 1/6：容忍连续 5 拍丢失仍不误判为「App 已退出」，
    /// 同时保证 helper 因 `KeepAlive` 重启后能在一个心跳周期内重新拿到指令。
    public static let heartbeatInterval: TimeInterval = 5

    /// 回执新鲜度窗口（秒）：超过它说明 helper 没在运行（未安装 / 被 `launchctl bootout` / 崩溃）。
    public static let statusFreshness: TimeInterval = 15
}
