import Foundation
import Darwin
import MacBatteryCore
import SMCBridge

// MacBattery root helper（launchd 常驻，以 root 运行）：
//
// 1) 整机功率（原有能力，行为不变）：每秒读一次 SMC 整机功耗（PSTR 等），
//    写到全局可读的 /tmp/macbattery_power.json，供无权限的 GUI app 显示真实功耗。
//
// 2) 充电上限（新增）：读 /tmp/macbattery_charge_cmd.json 里的指令，写 AppleSMC 的
//    充电抑制键（CH0B / CH0C），并把**实际**状态写回 /tmp/macbattery_charge_status.json。
//    GUI 侧无 root 权限，只能写 SMC 之外的东西；本进程是唯一的执行者。
//
// ── 安全边界（重要）──────────────────────────────────────────────────────────
// /tmp 是全局可写的，任何本地用户都能伪造指令文件。因此本进程**不接受任意指令**：
//   · 动作只有白名单两个取值（inhibit / allow，由 ChargeLimitWire.Action 决定）；
//   · 键只从 SMCChargeKey 列表取；
//   · 值只从 SMCChargeAllowValue / SMCChargeInhibitValue 取；
//   · 只写 dataSize == 1 的键，且只碰当前取值已是这两个已知值之一的键。
// 指令文件里没有任何字段能表达"写别的键 / 别的值"，最坏后果被限制在"切换充电抑制"，
// 不会演变成"任意 SMC 写入"的提权面。
//
// ── 故障安全（同样重要）──────────────────────────────────────────────────────
// 指令超过 ChargeLimitWire.commandFreshness 秒未刷新 → 视为 App 已退出 → 复位为
// 「允许充电」。宁可功能失效，也不能让"App 没在运行"变成"充电被永久禁止"：
// 那样用户会看到电量卡在上限再也充不满，而解除手段（重装 helper / SMC 复位）
// 不是普通用户能想到的。
//
// 安装方式见 Scripts/install_helper.sh（一次性 sudo）。

let outputPath = "/tmp/macbattery_power.json"
let interval: UInt32 = 1  // 秒

/// 本机 SMC 键名快照（惰性枚举、只枚举一次）。
///
/// 为什么需要它：候选键名（`CH0B` / `CH0C` / `BCLM` …）是我根据公开实现列出来的**猜测**。
/// 猜错就永远卡在「没找到可用的键」，而且每猜一轮都要用户重装一次 helper。
/// 枚举 SMC 键命名空间拿到的是**这台机器真实拥有的全部键名**，按前缀筛一遍即可给出确定答案。
///
/// 放进类而不是全局 `var`：可变全局状态在闭包里读写容易踩并发/exclusivity 的坑，
/// 类实例的内部状态语义清楚得多。
final class SMCKeySnapshot {
    private var cached: [String]?

    /// 本机的「充电相关」键名（只读探测用）。首次调用时枚举并缓存。
    func chargeRelatedKeys(_ conn: io_connect_t) -> [String] {
        if let cached { return cached }
        var discovered = enumerateChargeRelatedKeys(conn)
        discovered = Self.normalizedOrder(conn, names: discovered)
        cached = discovered
        return discovered
    }

    /// 遍历 SMC 键命名空间，留下充电相关的键名（去重、限量）。
    private func enumerateChargeRelatedKeys(_ conn: io_connect_t) -> [String] {
        var count: UInt32 = 0
        // 枚举不到（读不了 "#KEY"）就返回空 —— 上层的候选列表仍然会被探测，
        // 只是少了一份"这台机器到底有什么"的完整答案，不影响其它功能。
        guard SMCKeyCount(conn, &count) == 1, count > 0 else { return [] }

        var names: [String] = []
        var seen = Set<String>()
        var buffer = [CChar](repeating: 0, count: 8)

        for index in 0..<count {
            let ok = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
                SMCKeyNameAtIndex(conn, index, pointer.baseAddress)
            }
            guard ok == 1 else { continue }
            let name = String(cString: buffer)
            guard ChargeLimitWire.isChargeRelatedKey(name) else { continue }
            guard seen.insert(name).inserted else { continue }
            names.append(name)
            if names.count >= ChargeLimitWire.enumeratedKeyLimit { break }
        }
        return names
    }

    /// 校验枚举出来的键名**顺序**是否读得通。
    ///
    /// SMC 把 4 个字符打包成一个整数返回，字节序理解反了会得到 `B0HC` 而不是 `CH0B`
    /// —— 两者都是可打印 ASCII，光看字符没法发现。这里用「按名读一次」当判据：
    /// 顺序对了就至少有个样本读得到；一个都读不到就整体反转再试一次。
    /// 两条路都不通时原样返回（上层会把它们显示为缺失，不会误报成"存在"）。
    private static func normalizedOrder(_ conn: io_connect_t, names: [String]) -> [String] {
        // 显式 withCString 转换，不用 Swift 的 String→const char* 隐式转换：
        // 这里的指针只在这一行内有效，写法明确一点更不容易被误改。
        func readable(_ name: String) -> Bool {
            name.withCString { SMCProbeKey(conn, $0, nil, nil) == 1 }
        }

        if names.prefix(5).contains(where: readable) {
            return names
        }
        let reversed = names.map { String($0.reversed()) }
        if reversed.prefix(5).contains(where: readable) {
            return reversed
        }
        return names
    }
}

let keySnapshot = SMCKeySnapshot()

// 优雅停机：捕获 SIGTERM / SIGINT 退出，便于 launchd 重启。
signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }

// 主循环
while true {
    // 每轮用一个 autoreleasepool 包住读写：writePower / JSONEncoder 会经 Foundation
    // 产生自动释放对象。本进程以 launchd 守护常驻、几乎不会重启，若无池则内存单调增长。
    // sleep 放在池外，语义更直观。
    autoreleasepool {
        // SMC 连接每轮开一次、同时供功率读取与充电抑制写入使用：
        // 原先功率读取自己开关一次连接，加上充电抑制就会变成每秒两次开关。
        let conn = SMCOpen()
        let watts = conn != 0 ? readSystemPowerWatts(conn) : 0

        if conn != 0 {
            updateChargeLimit(conn)
            SMCClose(conn)
        } else {
            // SMC 打不开（休眠唤醒后偶发）→ 明确回报"暂不可用"。
            // 不写回执的话，App 会因为回执过期而误报"helper 未在运行"，
            // 把一次可自愈的故障描述成"需要重装"，指向完全错误的排查方向。
            // 带上专门的错误码，让 App 能把它与"机型不支持"区分开 —— 两者的后续动作完全不同。
            writeChargeStatus(supported: false,
                              inhibited: false,
                              keys: [],
                              error: ChargeLimitWire.Status.ErrorCode.smcOpenFailed,
                              probed: nil)
        }

        writePower(watts)
    }
    sleep(interval)
}

// MARK: - SMC 读取

func readSystemPowerWatts(_ conn: io_connect_t) -> Double {
    // 候选键来自 SMCBridge 的唯一定义处（与 SMC.swift 同源，顺序即探测优先级）。
    let count = SMCPowerKeyCount()
    for i in 0..<count {
        guard let key = SMCPowerKey(i) else { continue }
        let v = SMCGetFloatValue(conn, key)
        if v > 0, v.isFinite {
            return v
        }
    }
    return 0
}

// MARK: - 充电上限

/// 读出仍然"新鲜"的指令。
///
/// 指令不存在 / 解析失败 / 协议版本不符 / 时间戳超出新鲜度窗口 → 返回 nil，
/// 调用方按「允许充电」处理。所有失败路径都收敛到同一个安全结论，不需要各自兜底。
func readFreshCommand(now: Double) -> ChargeLimitWire.Command? {
    let url = URL(fileURLWithPath: ChargeLimitWire.commandPath)
    guard let data = try? Data(contentsOf: url),
          let command = try? JSONDecoder().decode(ChargeLimitWire.Command.self, from: data),
          // 协议版本不符：可能是 App 已升级而 helper 还是旧的。此时**拒绝执行**，
          // 而不是猜字段含义 —— 猜错的方向可能是"禁止充电"。
          command.proto == ChargeLimitWire.version,
          // 取绝对值：时间戳来自另一个进程，未来时间戳（系统时钟被改 / 被伪造）
          // 同样不可信，否则一条伪造的"永远新鲜"的指令会让抑制永久生效。
          abs(now - command.timestamp) <= ChargeLimitWire.commandFreshness
    else { return nil }
    return command
}

/// 把目标状态施加到硬件，返回「实际达成」的结果。
///
/// 要点：
/// · **当前值已是目标值时直接跳过写入** —— 这样从没启用过本功能的用户，
///   一次 SMC 写都不会发生；
/// · 写成功后必须**读回校验**：部分机型的固件会静默忽略写入，不看读回值就会向 App
///   谎报"已抑制"，用户在界面上看到"已限充"而电池仍在充；
/// · 只碰「当前取值已是已知两种之一」的键：读到别的值说明该键的语义与我们的理解不同
///   （不同机型/固件对 CH0B、CH0C 的解释并不统一），跳过它，不猜、不乱写。
func applyChargeState(_ conn: io_connect_t,
                      inhibit: Bool) -> (inhibited: Bool, keys: [String], error: String?) {
    let allow = SMCChargeAllowValue()
    let suppress = SMCChargeInhibitValue()
    let target = inhibit ? suppress : allow

    var usedKeys: [String] = []
    var verified = false
    var failure: String?

    let count = SMCChargeKeyCount()
    for i in 0..<count {
        guard let rawKey = SMCChargeKey(i) else { continue }
        let key = String(cString: rawKey)

        var current: UInt8 = 0
        // 读失败 = 本机型没有这个键，跳过。
        guard SMCReadByte(conn, rawKey, &current) == 1 else { continue }
        // 取值不认识 = 语义与我们理解的不同（见函数说明），跳过。
        guard current == allow || current == suppress else { continue }

        usedKeys.append(key)

        if current == target {
            verified = true
            continue
        }

        guard SMCWriteByte(conn, rawKey, target) == 1 else {
            failure = ChargeLimitWire.Status.ErrorCode.writeFailed
            continue
        }

        var readback: UInt8 = 0
        if SMCReadByte(conn, rawKey, &readback) == 1, readback == target {
            verified = true
        } else {
            failure = ChargeLimitWire.Status.ErrorCode.verifyFailed
        }
    }

    if usedKeys.isEmpty {
        // 一个可安全写入的键都没有 → 功能无法执行（"为什么"由 probeChargeKeys 报回 App）。
        return (false, [], ChargeLimitWire.Status.ErrorCode.noChargeKey)
    }
    guard verified else {
        // 键在、但没写成功（或被固件挡回）→ 不能声称已抑制。
        return (false, usedKeys, failure ?? ChargeLimitWire.Status.ErrorCode.noEffect)
    }
    // 部分键失败、部分成功时依然如实带上 error，供排查（App 界面只看 inhibited）。
    return (inhibit, usedKeys, failure)
}

/// 只读探测全部候选键（含枚举出来的本机键名），供 App 回答「为什么显示不支持」。
///
/// 两种成因必须分开：**键根本不存在**（没救）与**键存在但取值不认识**（缺一个取值映射）。
/// 没有这层观测时两者在回执里长得一样，用户只能看到一句无解的错误提示。
/// `used` 标出哪些键真被采用（参与写入 / 校验），其余即使存在也只是"看到了"。
func probeChargeKeys(_ conn: io_connect_t, usedKeys: [String]) -> [ChargeLimitWire.KeyProbe] {
    var probes: [ChargeLimitWire.KeyProbe] = []
    // 同一个键只报一次：候选列表与枚举结果必然重叠（CH0B/CH0C 既在候选里、也会被枚举到）。
    var seen = Set<String>()

    func probe(_ key: String) {
        guard seen.insert(key).inserted else { return }
        var size: UInt32 = 0
        var value: Int32 = -1
        // 显式 `withCString`：不依赖 Swift 的 String→const char* 隐式转换
        //（它在参数类型是 IUO 时不保证生效）。`withCString` 的闭包是**非逃逸**的，
        // 所以可以在里面用本地变量的 `&size` / `&value` 当 C 出参。
        let present = key.withCString { SMCProbeKey(conn, $0, &size, &value) == 1 }
        probes.append(ChargeLimitWire.KeyProbe(key: key,
                                              present: present,
                                              dataSize: Int(size),
                                              value: Int(value),
                                              used: usedKeys.contains(key)))
    }

    // ① 可写白名单（执行判定只看这两个）→ ② 额外候选 → ③ 枚举出来的本机键名。
    // 顺序有意义：前两组决定了下面的取值判定，枚举组纯粹是"这台机器还有什么"。
    for i in 0..<SMCChargeKeyCount() {
        if let rawKey = SMCChargeKey(i) { probe(String(cString: rawKey)) }
    }
    for i in 0..<SMCChargeProbeKeyCount() {
        if let rawKey = SMCChargeProbeKey(i) { probe(String(cString: rawKey)) }
    }
    for key in keySnapshot.chargeRelatedKeys(conn) {
        probe(key)
    }
    return probes
}

/// 每轮执行一次：读指令 → 施加 → 写回执。
func updateChargeLimit(_ conn: io_connect_t) {
    let now = Date().timeIntervalSince1970
    // 没有新鲜指令（App 未运行 / 已退出 / 心跳中断）→ 目标为「允许充电」。
    let targetInhibit = readFreshCommand(now: now)?.action == .inhibit
    let result = applyChargeState(conn, inhibit: targetInhibit)
    writeChargeStatus(supported: !result.keys.isEmpty,
                      inhibited: result.inhibited,
                      keys: result.keys,
                      error: result.error,
                      probed: probeChargeKeys(conn, usedKeys: result.keys))
}

// MARK: - 写入

func writeChargeStatus(supported: Bool,
                       inhibited: Bool,
                       keys: [String],
                       error: String?,
                       probed: [ChargeLimitWire.KeyProbe]?) {
    let status = ChargeLimitWire.Status(proto: ChargeLimitWire.version,
                                        supported: supported,
                                        inhibited: inhibited,
                                        keys: keys,
                                        timestamp: Date().timeIntervalSince1970,
                                        error: error,
                                        probed: probed)
    guard let data = try? JSONEncoder().encode(status) else { return }
    writeAtomically(data, to: ChargeLimitWire.statusPath)
}

func writePower(_ watts: Double) {
    let payload = "{\"systemPower\":\(watts)}"
    guard let data = payload.data(using: .utf8) else { return }
    writeAtomically(data, to: outputPath)
}

/// 原子写 + 放宽到 0644。
///
/// 桌面版 `Data.write` 的落盘权限受 umask 影响（通常是 0600），而读这个文件的 GUI
/// 以普通用户身份运行 —— 不改权限的话 App 永远读不到，表现为"helper 装了但没生效"。
func writeAtomically(_ data: Data, to path: String) {
    do {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        // 忽略；下次循环重试
        return
    }
    _ = path.withCString { pathCstr in
        Darwin.chmod(pathCstr, 0644)
    }
}
