import Foundation
import MacBatteryCore
import os

/// 充电上限的**驱动与回报**层（应用侧）。
///
/// 三层分工（不要混）：
/// · **决策**在 `ChargeLimitPolicy`（纯逻辑、可独立单测）；
/// · **执行**在 root helper（唯一有权限写 SMC 的进程，见 `MacBatteryHelper/main.swift`）；
/// · 本类型夹在中间：把决策变成指令文件、按心跳保活、把 helper 回执翻译成界面状态。
///
/// 线程约定：本类型是 `@MainActor`（状态要被 SwiftUI 直接读），但**文件 IO 一律丢到 `queue`**。
/// 这与项目其余部分一致 —— 挂件每 0.5s 刷新一次，主线程不做 IO。
@MainActor
final class ChargeLimiter: ObservableObject {

    /// helper 的可用性：决定「开关能不能真的断开充电」，与用户在设置里选的开关是两回事。
    /// 拆开的原因：开关是用户的意愿，可用性是本机的事实；把两者混成一个 Bool，
    /// 界面就只能显示「已开启」而无法解释「为什么电量还是充到了 100%」。
    enum Availability: Equatable {
        /// helper 在跑、本机也支持：开关打开后就能真的断开充电。
        case ready
        /// 不可用及其原因。
        case unavailable(reason: UnavailableReason)

        /// 不可用及其原因（不同原因对应完全不同的排查方向）。
        ///
        /// 具体取值定义在 `ChargeLimitWire`（纯逻辑层）：其中「由回执内容推导成因」是纯函数，
        /// 放在那边才能在 CI 里被单测覆盖 —— 本机没有 Swift 工具链，测试跑不到的映射等于没写。
        typealias UnavailableReason = ChargeLimitWire.UnavailableReason
    }

    /// 界面展示用的状态。
    ///
    /// 刻意做成枚举而不是拼好的字符串：文案要随界面语言走（`L()`），本类型不碰多语言。
    enum Phase: Equatable {
        /// 功能已关闭。
        case off
        /// 上限为 100%（= 不限制）：等价于关闭，不下发任何指令。
        case unlimited
        /// 开着但执行不了（helper 缺失 / 机型不支持）。
        case unavailable(Availability.UnavailableReason)
        /// 未接外电，上限暂不生效。
        case onBattery(limit: Int)
        /// 已接电、正在充电，会在上限处暂停。
        case charging(limit: Int)
        /// 已到上限，充电已暂停。
        case holding(limit: Int)
    }

    @Published private(set) var availability: Availability = .unavailable(reason: .notInstalled)
    @Published private(set) var phase: Phase = .off
    /// 配置镜像（由 `evaluate` 每拍刷新）：挂件与菜单栏读这里，不必再各持一份 `SettingsStore`。
    @Published private(set) var isEnabled = false
    @Published private(set) var limitPercent = ChargeLimitPolicy.defaultPercent
    /// helper 回执中「硬件实际处于抑制中」（经过读回校验，是事实而非意图）。
    @Published private(set) var inhibited = false
    /// 候选 SMC 键的只读探测摘要（`CH0B=0x02  CHTE=missing  BCLM=size4:50`）。
    ///
    /// 只在功能不可用时非空：这是「为什么本机不支持」的**唯一**答案来源 ——
    /// 键不存在、键存在但取值不认识、SMC 打不开，三种情况对用户意味着完全不同的动作。
    @Published private(set) var probeSummary: String?
    /// 最近一次回执的年龄（秒）；`nil` = 读不到回执（没装 / 没跑 helper）。
    ///
    /// 界面用它把「helper 在跑」这句话变成**可核对的事实**（回执 2 秒前），
    /// 而不是一句用户无法验证的断言 —— 排查「功能没生效」时，第一件事就是确认心跳还在跳。
    @Published private(set) var lastStatusAge: TimeInterval?
    /// SMC 是否可读。由回执推断，而不是另开一次探测：
    /// helper 能写出 `supported` / `keys` 就说明它成功打开了 SMC，
    /// 只有 `smc_open_failed` 表示连连接都没建立。
    @Published private(set) var smcReadable = false
    /// 本机实际使用的限制机制（`nil` = 未知 / 旧版 helper，按抑制机制理解）。
    ///
    /// 由 helper 探测后上报，App 按它选决策方式 —— 两套机制的语义不同，
    /// 各自猜一套必然错（抑制是开关、BCLM 是"最多充到多少"）。
    @Published private(set) var mechanism: ChargeLimitWire.Mechanism?

    private static let logger = Logger(subsystem: "com.zioon.macbattery", category: "charge-limit")

    /// 回执轮询间隔（秒）。回执只有百来字节，2s 一次足够跟上状态变化，也不打扰 helper。
    private static let statusPollInterval: TimeInterval = 2

    /// 文件 IO 专用串行队列（App 不阻塞主线程）。
    private let queue = DispatchQueue(label: "MacBattery.chargeLimit", qos: .utility)

    /// 最近一条**已确认写出**的指令（nil = 从未发过）。
    /// 用它做三道闸：只在指令变化时写盘、上限值变了立刻重发、只对「施加」做心跳保活。
    private var lastSent: ChargeLimitWire.Action?
    /// 最近一条指令里带的上限值（与 `lastSent` 配对）。
    private var lastSentLimit: Int?
    private var lastWriteTime: Date?
    private var lastStatusRead: Date?
    private var statusReadInFlight = false
    private var writeInFlight = false
    /// 最近一次「不可用」的补充说明（SMC 探测摘要），只用于日志。
    /// 让「开关点了没反应」这类问题在日志里就有答案，不必让用户去 /tmp 里翻 JSON。
    private var logUnavailableDetail: String?
    /// 是否已经知道本机机制。
    ///
    /// 与 `mechanism == nil` 不是一回事：`nil` 可能是「旧版 helper（只有抑制机制）」，
    /// 也可能是「还不知道」。前者可以照旧下发指令，后者不能 —— 见 `evaluate` 的下发护栏。
    private var mechanismKnown = false

    init() {
        // 首次回执读取刻意**同步**完成：设置面板与挂件可能在第一帧就要显示状态，
        // 异步读会让界面先闪一下「未安装 helper」再跳成正常。
        // 代价是启动时读一个 ≤200 字节、通常还不存在的文件 ——
        // 与 `SettingsStore` 读 UserDefaults、语言引擎读 `.strings` 同属启动路径上的小 IO。
        apply(status: Self.readStatus(), now: Date())
    }

    /// 每个采样点调用一次（主线程，由 `PowerMonitor.apply` 驱动）。
    ///
    /// 顺序不能换：先刷新配置镜像与回执，再决策 —— 决策依赖「硬件当前是否已抑制」，
    /// 用旧回执会多下发一次无意义的指令。
    func evaluate(level: Int,
                  isCharging: Bool,
                  onBattery: Bool,
                  enabled: Bool,
                  limit: Int) {
        let now = Date()
        let clampedLimit = ChargeLimitPolicy.clamp(limit)
        let wasEnabled = isEnabled
        isEnabled = enabled
        limitPercent = clampedLimit

        readStatusIfDue(now: now)
        logEnableTransitionIfNeeded(wasEnabled: wasEnabled, enabled: enabled)

        let action = decideAction(level: level,
                                  onBattery: onBattery,
                                  limit: clampedLimit,
                                  enabled: enabled)
        // 机制未知时一律不下发：抑制与 BCLM 的「解除」含义不同（写 `0x00` vs 写 `100`），
        // 猜错方向的代价是**把用户设的上限整个撤掉**。等回执到了再动手，最多晚一个轮询周期。
        if mechanismKnown {
            switch action {
            case .applyLimit:
                send(.inhibit, limit: clampedLimit, now: now,
                     heartbeat: ChargeLimitWire.heartbeatInterval)
            case .releaseLimit:
                send(.allow, limit: clampedLimit, now: now, heartbeat: nil)
            case .noChange:
                // `.noChange` 有多个来源（功能关闭 / 上限 100% / 未接外电）。只有前两者需要
                // 「解除一次」；未接外电时不该动硬件 —— 与决策层 `action(...)` 的判断保持一致。
                if (!enabled || clampedLimit >= ChargeLimitPolicy.maximumPercent), hardwareInhibited {
                    send(.allow, limit: clampedLimit, now: now, heartbeat: nil)
                }
            }
        }

        updatePhase(level: level, isCharging: isCharging,
                    onBattery: onBattery, limit: clampedLimit, enabled: enabled)
    }

    /// 按本机机制选决策方式。
    ///
    /// 这是两套机制**唯一**的接缝处，刻意做成一处显式分派而不是把它们揉进同一个判定：
    /// 抑制机制是"到上限就停、回落到迟滞带以下再恢复"的开关逻辑；
    /// 最大充电量（BCLM）是持久的上限值，按电量来回切会在电量回落时把上限整个撤掉。
    private func decideAction(level: Int,
                              onBattery: Bool,
                              limit: Int,
                              enabled: Bool) -> ChargeLimitPolicy.Action {
        if mechanism == .bclm {
            return ChargeLimitPolicy.levelCapAction(enabled: enabled, limit: limit)
        }
        return ChargeLimitPolicy.action(level: level,
                                        limit: limit,
                                        enabled: enabled,
                                        onExternalPower: !onBattery,
                                        currentlyInhibited: hardwareInhibited)
    }

    // MARK: - 状态推导

    /// 硬件当前是否处于抑制中，供决策使用。
    ///
    /// 有回执时以回执为准（它经过 helper 的读回校验，是事实）；
    /// 没有回执时退回「我们最近下发过什么」—— 那只是意图，仅在无法求证时使用。
    private var hardwareInhibited: Bool {
        if case .ready = availability { return inhibited }
        return lastSent == .inhibit
    }

    private func updatePhase(level: Int,
                             isCharging: Bool,
                             onBattery: Bool,
                             limit: Int,
                             enabled: Bool) {
        guard enabled else {
            phase = .off
            return
        }
        guard limit < ChargeLimitPolicy.maximumPercent else {
            phase = .unlimited
            return
        }
        if case .unavailable(let reason) = availability {
            phase = .unavailable(reason)
            return
        }
        if onBattery {
            phase = .onBattery(limit: limit)
            return
        }
        // 「已限充」以 `!isCharging` 为准而不是「指令已下发」：前者才是用户能观察到的事实。
        if !isCharging, ChargeLimitPolicy.isAtLimit(level: level, limit: limit, enabled: enabled) {
            phase = .holding(limit: limit)
            return
        }
        phase = .charging(limit: limit)
    }

    // MARK: - 下发指令

    /// 下发动作。只有「与最近一条不同」或「抑制心跳到期」时才真正写盘 ——
    /// `evaluate` 每 0.5s 被调用一次，不加这道闸就是每秒两次文件写。
    private func send(_ action: ChargeLimitWire.Action,
                      limit: Int,
                      now: Date,
                      heartbeat: TimeInterval?) {
        guard !writeInFlight,
              shouldSend(action, limit: limit, now: now, heartbeat: heartbeat) else { return }

        let command = ChargeLimitWire.Command(action: action,
                                              limit: limit,
                                              timestamp: now.timeIntervalSince1970)
        writeInFlight = true
        queue.async { [weak self] in
            let written = Self.writeCommand(command)
            // 捕获列表必须显式写 `[weak self]`：外层已经是 weak 捕获，内层闭包直接引用
            // 那个（可变的）捕获变量会被并发检查判为 "reference to captured var 'self' in
            // concurrently-executing code" —— 在 CI 上是编译错误，不是警告。
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.writeInFlight = false
                guard written else { return }
                self.lastSent = action
                self.lastSentLimit = limit
                self.lastWriteTime = now
            }
        }
    }

    private func shouldSend(_ action: ChargeLimitWire.Action,
                            limit: Int,
                            now: Date,
                            heartbeat: TimeInterval?) -> Bool {
        guard lastSent == action else { return true }
        // 上限值变了也要立刻重发：对「最大充电量」机制来说 `limit` 就是**写进硬件的值**，
        // 只靠心跳拖着，用户拖完滑块要等最多一个心跳周期才生效。
        guard lastSentLimit == limit else { return true }
        // 目标与最近一条相同：只有「施加」需要心跳保活。
        // 「解除」是故障安全默认值（指令过期后 helper 自己会回到它），刷不刷都一样。
        guard action == .inhibit, let heartbeat else { return false }
        guard let last = lastWriteTime else { return true }
        return now.timeIntervalSince(last) >= heartbeat
    }

    // MARK: - helper 回执

    private func readStatusIfDue(now: Date) {
        guard !statusReadInFlight else { return }
        if let last = lastStatusRead,
           now.timeIntervalSince(last) < Self.statusPollInterval {
            return
        }
        lastStatusRead = now
        statusReadInFlight = true
        queue.async { [weak self] in
            let status = Self.readStatus()
            // 同上：内层闭包显式 weak 捕获，别依赖外层那个 weak 捕获变量。
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statusReadInFlight = false
                self.apply(status: status, now: Date())
            }
        }
    }

    /// 把回执翻译成可用性状态。每条失败路径各有各的原因，对应界面上的不同提示。
    private func apply(status: ChargeLimitWire.Status?, now: Date) {
        guard let status else {
            // 读不到回执 = helper 没装 / 没在跑，此时「它能不能读 SMC」无从谈起。
            lastStatusAge = nil
            smcReadable = false
            mechanismKnown = false
            mechanism = nil
            setAvailability(.unavailable(reason: .notInstalled))
            inhibited = false
            probeSummary = nil
            logUnavailableDetail = nil
            return
        }
        // 回执年龄先算出来：界面上「运行中」要能核对（回执 2 秒前），而不是一句空断言。
        // 用 max(0, ·) —— 两个进程的时钟可能有一点点偏差，负数会让界面显示「-1 秒前」。
        lastStatusAge = max(0, now.timeIntervalSince1970 - status.timestamp)

        // 版本不符 = 老 helper 配新 App。执行与否由 helper 侧决定（它同样会拒绝），
        // App 只负责把「请重装 helper」这件事说清楚。
        guard status.proto == ChargeLimitWire.version else {
            // 旧 helper 的字段不能按新语义解读，因此「SMC 可读」也不下结论。
            smcReadable = false
            mechanismKnown = false
            mechanism = nil
            setAvailability(.unavailable(reason: .outdatedHelper))
            inhibited = false
            probeSummary = nil
            logUnavailableDetail = nil
            return
        }
        guard now.timeIntervalSince1970 - status.timestamp <= ChargeLimitWire.statusFreshness else {
            // 回执过期 = helper 没在跑，它上一次报的 SMC 状态已经不代表现在。
            smcReadable = false
            setAvailability(.unavailable(reason: .notRunning))
            inhibited = false
            probeSummary = nil
            logUnavailableDetail = nil
            return
        }
        guard status.supported else {
            // `supported == false` 有三种成因，必须分开：机型没救 / 缺取值映射 / SMC 打不开。
            // 先填诊断信息再切状态 —— 状态切换里会记日志，晚一步就会把上一条诊断记进日志。
            smcReadable = status.error != ChargeLimitWire.Status.ErrorCode.smcOpenFailed
            probeSummary = Self.summarize(status.probed)
            logUnavailableDetail = probeSummary
            // 机制照样采纳："本机没有机制"与"还不知道机制"是两回事（见 evaluate 的下发护栏）。
            mechanismKnown = true
            mechanism = status.mechanism
            setAvailability(.unavailable(reason: ChargeLimitWire.unavailableReason(for: status)))
            inhibited = false
            return
        }
        smcReadable = true
        // 旧版 helper 不带 mechanism 字段 → nil，按抑制机制理解（那是旧版唯一的机制）。
        mechanismKnown = true
        mechanism = status.mechanism
        setAvailability(.ready)
        inhibited = status.inhibited
        probeSummary = nil
        logUnavailableDetail = nil
    }

    private static func summarize(_ probes: [ChargeLimitWire.KeyProbe]?) -> String? {
        // 只留存在的键：把 missing 也列出来会让这一行长得没法看，而"键不存在"这个信息
        // 已经被 `unsupportedHardware` 这条提示覆盖了。
        guard let probes else { return nil }
        let present = probes.filter { $0.present }
        guard !present.isEmpty else { return nil }
        return present.map { $0.summary }.joined(separator: "  ")
    }

    /// 可用性变化时记一行日志。排查「开关点了没反应」时，这一行直接给出方向：
    /// 没装 helper、helper 没在跑、机型不支持，三者的处置完全不同。
    private func setAvailability(_ new: Availability) {
        guard new != availability else { return }
        availability = new
        // 功能从未启用过就不记：没装 helper 的用户每次启动都会多一行与自己无关的噪音。
        guard isEnabled else { return }
        switch new {
        case .ready:
            Self.logger.notice("充电上限：root helper 就绪")
        case .unavailable(let reason):
            let detail = logUnavailableDetail ?? "-"
            Self.logger.error("充电上限：不可用（\(String(describing: reason), privacy: .public)）探测 \(detail, privacy: .public)")
        }
    }

    private func logEnableTransitionIfNeeded(wasEnabled: Bool, enabled: Bool) {
        guard enabled, !wasEnabled else { return }
        switch availability {
        case .ready:
            Self.logger.notice("充电上限：已启用（helper 就绪）")
        case .unavailable(let reason):
            let detail = logUnavailableDetail ?? "-"
            Self.logger.error("充电上限：已启用但不可用（\(String(describing: reason), privacy: .public)）探测 \(detail, privacy: .public)")
        }
    }

    // MARK: - 文件 IO（后台队列）

    private nonisolated static func readStatus() -> ChargeLimitWire.Status? {
        let url = URL(fileURLWithPath: ChargeLimitWire.statusPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChargeLimitWire.Status.self, from: data)
    }

    private nonisolated static func writeCommand(_ command: ChargeLimitWire.Command) -> Bool {
        guard let data = try? JSONEncoder().encode(command) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: ChargeLimitWire.commandPath), options: .atomic)
        } catch {
            return false
        }
        return true
    }
}
