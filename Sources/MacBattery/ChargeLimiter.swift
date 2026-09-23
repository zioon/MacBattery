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
        /// 不可用及其原因（不同原因对应完全不同的排查方向）。
        case unavailable(reason: UnavailableReason)

        enum UnavailableReason: Equatable {
            /// 读不到回执文件：还没装 helper。
            case notInstalled
            /// 回执存在但已过期：装了但没在跑（被停用 / 崩溃 / 被卸载）。
            case notRunning
            /// 回执协议版本与 App 不一致：装的是旧版 helper，需要重装。
            case outdatedHelper
            /// 回执说本机没有可安全写入的充电抑制键。
            case unsupportedHardware
        }
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

    private static let logger = Logger(subsystem: "com.zioon.macbattery", category: "charge-limit")

    /// 回执轮询间隔（秒）。回执只有百来字节，2s 一次足够跟上状态变化，也不打扰 helper。
    private static let statusPollInterval: TimeInterval = 2

    /// 文件 IO 专用串行队列（App 不阻塞主线程）。
    private let queue = DispatchQueue(label: "MacBattery.chargeLimit", qos: .utility)

    /// 最近一条**已确认写出**的指令（nil = 从未发过）。
    /// 用它做两道闸：只在指令变化时写盘、只对「抑制」做心跳保活。
    private var lastSent: ChargeLimitWire.Action?
    private var lastWriteTime: Date?
    private var lastStatusRead: Date?
    private var statusReadInFlight = false
    private var writeInFlight = false

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

        let action = ChargeLimitPolicy.action(level: level,
                                              limit: clampedLimit,
                                              enabled: enabled,
                                              onExternalPower: !onBattery,
                                              currentlyInhibited: hardwareInhibited)
        switch action {
        case .inhibitCharging:
            send(.inhibit, limit: clampedLimit, now: now,
                 heartbeat: ChargeLimitWire.heartbeatInterval)
        case .allowCharging:
            send(.allow, limit: clampedLimit, now: now, heartbeat: nil)
        case .noChange:
            // 关闭功能（或把上限改成 100%）时也要「放行一次」：否则上一条抑制指令会一直
            // 留到新鲜度窗口过期（30s）才被 helper 复位，用户会觉得「关了还在限充」。
            if (!enabled || clampedLimit >= ChargeLimitPolicy.maximumPercent), hardwareInhibited {
                send(.allow, limit: clampedLimit, now: now, heartbeat: nil)
            }
        }

        updatePhase(level: level, isCharging: isCharging,
                    onBattery: onBattery, limit: clampedLimit, enabled: enabled)
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
        guard !writeInFlight, shouldSend(action, now: now, heartbeat: heartbeat) else { return }

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
                self.lastWriteTime = now
            }
        }
    }

    private func shouldSend(_ action: ChargeLimitWire.Action,
                            now: Date,
                            heartbeat: TimeInterval?) -> Bool {
        guard lastSent == action else { return true }
        // 目标与最近一条相同：只有「抑制」需要心跳保活。
        // 「允许」是故障安全默认值（指令过期后 helper 自己会回到它），刷不刷都一样。
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

    /// 把回执翻译成可用性状态。四条失败路径各有各的原因，对应界面上的不同提示。
    private func apply(status: ChargeLimitWire.Status?, now: Date) {
        guard let status else {
            setAvailability(.unavailable(reason: .notInstalled))
            inhibited = false
            return
        }
        // 版本不符 = 老 helper 配新 App。执行与否由 helper 侧决定（它同样会拒绝），
        // App 只负责把「请重装 helper」这件事说清楚。
        guard status.proto == ChargeLimitWire.version else {
            setAvailability(.unavailable(reason: .outdatedHelper))
            inhibited = false
            return
        }
        guard now.timeIntervalSince1970 - status.timestamp <= ChargeLimitWire.statusFreshness else {
            setAvailability(.unavailable(reason: .notRunning))
            inhibited = false
            return
        }
        guard status.supported else {
            setAvailability(.unavailable(reason: .unsupportedHardware))
            inhibited = false
            return
        }
        setAvailability(.ready)
        inhibited = status.inhibited
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
            Self.logger.error("充电上限：不可用（\(String(describing: reason), privacy: .public)）")
        }
    }

    private func logEnableTransitionIfNeeded(wasEnabled: Bool, enabled: Bool) {
        guard enabled, !wasEnabled else { return }
        switch availability {
        case .ready:
            Self.logger.notice("充电上限：已启用（helper 就绪）")
        case .unavailable(let reason):
            Self.logger.error("充电上限：已启用但 helper 不可用（\(String(describing: reason), privacy: .public)）")
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
