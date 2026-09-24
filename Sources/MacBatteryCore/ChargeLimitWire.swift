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

    /// 单个 SMC 键的**只读探测**结果。
    ///
    /// 为什么要带上它：界面上的「本机不支持」其实有两种**完全不同的成因** ——
    /// ① 这台机器根本没有这些键（没救）；② 有键，但当前取值不是我们认识的两个值，
    /// 于是被跳过（只是缺一个取值映射）。没有这层观测时，两者在回执里长得一模一样，
    /// 用户看到的是一句无解的错误提示，排查只能靠猜。
    /// helper 是**唯一**能读 SMC 的进程，由它把「看到了什么」原样带回来是最省事的做法。
    public struct KeyProbe: Codable, Equatable {
        /// 键名（4 字符，如 `CH0B`）。
        public var key: String
        /// 键是否存在。
        public var present: Bool
        /// 该键的 dataSize；键不存在时为 0。**不为 1** 说明它不是单字节开关量。
        public var dataSize: Int
        /// 首字节原始取值；读不到时为 -1。
        public var value: Int
        /// 本进程是否采用了它（参与写入 / 读回校验）。
        public var used: Bool

        public init(key: String, present: Bool, dataSize: Int, value: Int, used: Bool) {
            self.key = key
            self.present = present
            self.dataSize = dataSize
            self.value = value
            self.used = used
        }

        /// 一行可读形式：`CH0B=0x02` / `CHTE=missing` / `BCLM=size4:50`。
        /// 刻意是语言无关的（键名 + 十六进制），不做本地化 —— 它是排查数据，不是文案。
        public var summary: String {
            guard present else { return "\(key)=missing" }
            guard dataSize == 1 else { return "\(key)=size\(dataSize):\(value)" }
            return "\(key)=0x" + String(format: "%02X", value)
        }
    }

    /// helper → App 的回执。
    public struct Status: Codable, Equatable {
        public var proto: Int
        /// 本机是否存在**可安全写入**的充电抑制键。false = 功能无法执行。
        ///
        /// ⚠️ 注意 `supported == false` **不等价于**「机型不支持」：也可能是
        /// 「键存在但取值不认识」或「SMC 打不开」。用 `probed` / `error` 区分，
        /// 否则界面只能给出一句用户无法处理的提示。
        public var supported: Bool
        /// helper 当前**实际**施加的状态（写完做了读回校验后才置位）。
        public var inhibited: Bool
        /// 实际用到的 SMC 键名（排查用；跳过/不认识的键不会出现在这里）。
        public var keys: [String]
        /// 回执时间（Unix epoch 秒）。App 靠它判断 helper 是否还在运行。
        public var timestamp: Double
        /// 失败原因**代码**（取值见 `ErrorCode`）。
        /// 刻意用代码而不是文案：文案由 App 侧本地化，helper 不参与多语言。
        public var error: String?
        /// 候选键的只读探测结果（含可写白名单与额外候选）。
        /// 可选：旧版 helper 不写这个字段，`nil` 时 App 退回「键一个都没有」的判断。
        public var probed: [KeyProbe]?

        public init(proto: Int,
                    supported: Bool,
                    inhibited: Bool,
                    keys: [String],
                    timestamp: Double,
                    error: String?,
                    probed: [KeyProbe]? = nil) {
            self.proto = proto
            self.supported = supported
            self.inhibited = inhibited
            self.keys = keys
            self.timestamp = timestamp
            self.error = error
            self.probed = probed
        }

        /// `error` 字段的取值（唯一定义处）。
        ///
        /// 用常量而不是各写一份裸字符串：这一串同时被两个进程使用，拼错不会报错，
        /// 只会让 App 走进错误的提示分支 —— 而错误提示恰恰是用户唯一能看到的线索。
        public enum ErrorCode {
            /// SMC 连接打不开（休眠唤醒后偶发 / 环境异常）：**不是**机型不支持。
            public static let smcOpenFailed = "smc_open_failed"
            /// 一个可安全写入的充电键都没有。
            public static let noChargeKey = "no_charge_key"
            /// 写入被内核拒绝。
            public static let writeFailed = "write_failed"
            /// 写入成功但读回值不符（固件静默忽略）。
            public static let verifyFailed = "verify_failed"
            /// 键存在但施加后没看到效果。
            public static let noEffect = "no_effect"
        }
    }

    /// 「本功能为什么不可用」。
    ///
    /// 定义在本层而不是 App 层：前三个成因由 App 侧的读取结果决定（回执文件不在 / 回执过期 /
    /// 协议版本不符），后三个由**回执内容**决定（见 `unavailableReason(for:)`）—— 后者是纯函数，
    /// 放在这里才能被 CI 单测覆盖。这条映射直接决定用户看到哪一句提示，而提示错的代价是
    /// 用户拿到一个自己无法处理的结论。
    public enum UnavailableReason: Equatable {
        /// 读不到回执文件：还没装 helper。
        case notInstalled
        /// 回执存在但已过期：装了但没在跑（被停用 / 崩溃 / 被卸载）。
        case notRunning
        /// 回执协议版本与 App 不一致：装的是旧版 helper，需要重装。
        case outdatedHelper
        /// 本机一个充电抑制键都没有（探测结果为空）。
        case unsupportedHardware
        /// 键**存在**，但当前取值不在已知的「允许 / 抑制」取值内，为避免误写而跳过。
        ///
        /// 与 `unsupportedHardware` 严格分开：一个有键但缺取值映射，一个压根没有键 ——
        /// 混在一起时用户看到的「本机不支持」既无法处理也无法排查。
        case unrecognizedValues
        /// helper 在跑，但 SMC 打不开：属环境问题，**不是**机型不支持。
        case smcUnreadable
    }

    /// 由回执内容推导「为什么不可用」。
    ///
    /// 判据只有两条，都是 helper 亲眼看过的：
    /// · 带了 `smc_open_failed` → 连 SMC 都没打开，与环境有关；
    /// · 探测里**有键存在** → 键在、只是取值不认识（缺一个取值映射）；一个都没有才是真没有这些键。
    public static func unavailableReason(for status: Status) -> UnavailableReason {
        if status.error == Status.ErrorCode.smcOpenFailed {
            return .smcUnreadable
        }
        let present = (status.probed ?? []).filter { $0.present }
        // 旧版 helper 不带 probed（nil）→ 退回「没有可用键」的判断。
        return present.isEmpty ? .unsupportedHardware : .unrecognizedValues
    }

    /// 充电相关键名的前缀。
    ///
    /// 刻意放宽到 2 个字符：枚举的目的就是**不再靠猜键名**，滤太严会把我们没听说过的机制
    /// 一起滤掉（T2 机型、Apple Silicon 各代用的键并不统一）。多几条无关键的代价，
    /// 远小于"又一次没找到可用的键"。
    public static let chargeRelatedKeyPrefixes = ["CH", "BC", "BF", "AC"]

    /// 回执里最多携带多少个「枚举到的额外键」。
    /// 枚举是"把本机所有充电相关键都列出来"，不设上限会把每秒一次的回执写成几十 KB。
    public static let enumeratedKeyLimit = 24

    /// 判断一个 SMC 键名是否与充电控制相关（枚举结果的过滤器）。
    ///
    /// 只接受**恰好 4 个字符**且前缀命中的名字：SMC 键名恒为 4 个 ASCII 字符，
    /// 长度不对说明枚举出来的东西不是键名（字节序或协议理解有误），宁可丢掉也不上报垃圾。
    public static func isChargeRelatedKey(_ name: String) -> Bool {
        guard name.count == 4 else { return false }
        return chargeRelatedKeyPrefixes.contains { name.hasPrefix($0) }
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
