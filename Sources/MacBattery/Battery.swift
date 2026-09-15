import Foundation
import IOKit
import IOKit.ps

/// 电池信息读取。全部采用 macOS 官方公开 API，无需 root 权限。
/// 注册表读取既可能来自后台串行采样队列，也可能来自主线程入口（电源事件补采样 / 健康日志），
/// 因此静态缓存（service 句柄 / 事件时间 / pmset 缓存）统一由 `lock` 保护。
enum BatteryReader {

    /// 保护本类型静态状态的锁：`cachedService`、`lastEventRefTime`、`pmsetCache` / `pmsetCacheTime`。
    /// 用 `NSRecursiveLock`（而非 `NSLock`）以容忍同类型内的嵌套调用；目标 macOS 12，
    /// 不使用 macOS 13+ 的 `OSAllocatedUnfairLock`。**该锁绝不跨 `pmset` 子进程调用持有。**
    private static let lock = NSRecursiveLock()

    /// 缓存的 AppleSmartBattery 服务句柄（0 表示尚未匹配）。复用避免高频反复匹配/释放。
    /// 受 `lock` 保护。
    private static var cachedService: io_service_t = 0

    /// 最近一次电源事件（插拔）发生时间（ReferenceDate）。事件回调（主线程）写入，
    /// 采样线程只读；读写均在 `lock` 临界区内（不再是"Double 竞态可忽略"）。
    /// 事件后短暂以 IOPS 即时状态为准，加快断电感知。
    private static var lastEventRefTime: TimeInterval = 0
    /// 电源事件后以 IOPS 即时状态覆盖 pmset 的窗口（秒）。
    private static let eventImmediateWindow: TimeInterval = 2.5

    /// 由电源事件回调调用，记录一次插拔事件。之后 `chargingStatus()` 在短窗口内
    /// 优先读取 IOPS 即时状态（与系统菜单栏电池图标同步、无子进程无缓存）。
    static func markBatteryEvent() {
        // 保护静态状态 `lastEventRefTime`：与 `chargingStatus()` 的读取互斥。
        lock.lock()
        defer { lock.unlock() }
        lastEventRefTime = Date().timeIntervalSinceReferenceDate
    }

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

    /// 当前充电功率（瓦特）与是否正在充电。
    ///
    /// 通过 AppleSmartBattery 的 `Voltage`(mV) × `Amperage`(mA) 计算。
    /// `Amperage` 为负时表示电流正在充入电池，取绝对值即为充电功率。
    static func chargingStatus() -> (isCharging: Bool, watts: Double, voltage: Double, current: Double) {
        var ampere = 0
        var volt = 0
        var chargingFlag = 0
        var sinceEvent = TimeInterval.greatestFiniteMagnitude
        var eventImmediate: Bool?

        // ── 加锁临界区（以 pmset 子进程调用为界，必须在其之前结束）──────────────
        // 保护的静态状态：
        //  · cachedService：取句柄 + 读属性 + 句柄失效时的 rebuildService（含 IOObjectRelease）
        //    必须串行；否则休眠唤醒后句柄失效，与另一线程的读取重叠会 use-after-free。
        //  · lastEventRefTime：与 markBatteryEvent() 的写入互斥。
        //  · pmsetCache：事件分支里主动置 nil 以强制下次刷新，写入需与 pmsetBatteryStatus 同步。
        // 临界区内无任何子进程调用（pmsetBatteryStatus 在锁外调用）。
        lock.lock()

        let service = currentService()
        guard service != 0, var props = readProperties(service) else {
            lock.unlock()
            return (false, 0, 0, 0)
        }

        ampere = intValue(props["Amperage"])
        volt = intValue(props["Voltage"])
        chargingFlag = intValue(props["IsCharging"])

        // 三个关键属性都读不到 → 缓存的句柄可能因休眠失效，重建服务并重试一次。
        if ampere == 0 && volt == 0 && chargingFlag == 0 {
            let rebuilt = rebuildService()
            if rebuilt != 0, let retry = readProperties(rebuilt) {
                props = retry
                ampere = intValue(retry["Amperage"])
                volt = intValue(retry["Voltage"])
                chargingFlag = intValue(retry["IsCharging"])
            }
        }

        sinceEvent = Date().timeIntervalSinceReferenceDate - Self.lastEventRefTime
        if sinceEvent < Self.eventImmediateWindow {
            // ioPSIsCharging 只读 IOPS（无锁、无子进程），可在临界区内安全调用。
            eventImmediate = Self.ioPSIsCharging()
            // 仅当 IOPS 即时状态可用时才让 pmset 缓存失效（与下方分支判定保持一致）。
            if eventImmediate != nil { Self.pmsetCache = nil }
        }

        lock.unlock()
        // ── 结束临界区（此后才允许调用 pmset 子进程）──────────────────────────

        // Amperage(mA) 负=充入、正=放电；Voltage(mV)。
        // 充电状态判定：
        // - 插拔事件后的短窗口内：优先用 IOPS 即时状态（与系统菜单栏电池图标同步、
        //   无子进程/无缓存，插拔立即反映），并让 pmset 缓存失效等待系统文本随之刷新；
        // - 其余时间：以 `pmset -g batt` 为权威（charging = 含 "charging" 且不含
        //   "discharging"）；pmset 进程失败时退回 IOPS / IsCharging 标志 / 电流方向综合判定。
        let isCharging: Bool
        if let io = eventImmediate {
            isCharging = io
        } else if let pmset = Self.pmsetBatteryStatus() {
            isCharging = pmset.charging
        } else {
            isCharging = (Self.ioPSIsCharging() ?? (chargingFlag == 1)) || (ampere < 0 && volt > 0)
        }

        // 电压/电流/功率与充电状态的关系：
        // - 电压/电流恒返回读数（mV/mA 转 V/A）；
        // - 充电功率严格跟随 isCharging：pmset 权威判定为充电时才有功率。
        //   ampere<0 的电流方向兜底只在 pmset 不可用分支里已纳入 isCharging，
        //   这里不再叠加，避免部分机型 Amperage 符号约定相反（放电也为负）被误当充电。
        let voltValue = Double(volt) / 1000.0
        let ampereAbs = Double(abs(ampere))
        let watts = (isCharging && volt > 0 && ampere != 0)
            ? ampereAbs * Double(volt) / 1_000_000.0
            : 0
        return (isCharging, watts, voltValue, ampereAbs / 1000.0)
    }

    /// 电池健康信息（变化缓慢，供健康图表按需读取）。
    struct BatteryHealth {
        /// 当前最大容量（mAh，AppleRawMaxCapacity）
        var maxCapacity: Int
        /// 设计容量（mAh，DesignCapacity）
        var designCapacity: Int
        /// 电池健康度（% = 当前最大容量 / 设计容量）
        var healthPercent: Double
        /// 充放电循环次数（CycleCount）
        var cycleCount: Int
    }

    /// 读取电池健康信息（当前最大容量 / 设计容量 / 健康度 / 循环次数）。
    /// 部分机型 AppleSmartBattery 的容量键可能有缺省（如 `DesignCapacity` 为 0），
    /// 因此只要「当前最大容量」可读就返回记录；健康度仅在设计容量可读时计算，否则记为 0。
    static func health() -> BatteryHealth? {
        // 保护静态状态 `cachedService`：与 chargingStatus() 的句柄读取/重建互斥，
        // 避免并发 use-after-free。函数内无子进程，可整体持锁。
        lock.lock()
        defer { lock.unlock() }

        let service = currentService()
        guard service != 0, let props = readProperties(service) else { return nil }
        // 当前最大容量：优先 AppleRawMaxCapacity，缺省时退回 MaxCapacity。
        let maxCap = firstPositive(intValue(props["AppleRawMaxCapacity"]),
                                   intValue(props["MaxCapacity"]))
        guard maxCap > 0 else { return nil }
        // 设计容量：优先 DesignCapacity，缺省时退回 MaxCapacity（作为粗略退路）。
        let designCap = firstPositive(intValue(props["DesignCapacity"]),
                                      intValue(props["MaxCapacity"]))
        let health: Double = designCap > 0
            ? Double(maxCap) / Double(designCap) * 100.0
            : 0
        return BatteryHealth(
            maxCapacity: maxCap,
            designCapacity: designCap,
            healthPercent: health,
            cycleCount: intValue(props["CycleCount"])
        )
    }

    /// 返回第一个 >0 的值；全部 ≤0 时返回 0。
    private static func firstPositive(_ a: Int, _ b: Int) -> Int {
        if a > 0 { return a }
        return b > 0 ? b : 0
    }

    /// 用 `pmset -g batt` 判定电池状态，解析规则与 MacMonitor 的 fetchBattery 完全一致：
    /// - onAC      = 输出含 "AC Power"（插着电源）
    /// - charging  = 含 "charging" 且不含 "discharging"（正在充电）
    /// - charged   = 含 "charged" 或 "finishing charge"（已充满 / 收尾充电）
    /// pmset 与系统菜单栏电池图标同源；5 秒内复用上次结果，避免每 0.5s 采样拉起进程。
    /// 本函数可被后台采样线程与主线程并发调用，缓存读写由 `lock` 保护；
    /// **子进程部分不持锁** —— 极端情况下两个线程可能同时未命中缓存各拉起一次 pmset，
    /// 这是良性的（最多多一个瞬时进程，解析结果一致），不影响正确性。进程启动失败时返回 nil。
    private static var pmsetCacheTime: TimeInterval = 0
    private static var pmsetCache: (onAC: Bool, charging: Bool, charged: Bool)?

    private static func pmsetBatteryStatus() -> (onAC: Bool, charging: Bool, charged: Bool)? {
        let now = Date().timeIntervalSinceReferenceDate

        // 缓存读取：短临界区（pmsetCache / pmsetCacheTime 由多个入口并发读写）。
        lock.lock()
        if let cached = pmsetCache, now - pmsetCacheTime < 5.0 {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }

        // 超时保护：约 1.5s 后若子进程仍在运行则终止它，
        // 使下方的 readDataToEndOfFile() 因管道关闭而返回，避免永久卡死。
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5, execute: timeout)

        // 先读管道再等退出：避免子进程输出超过管道缓冲（约 64KB）时双方互等。
        // 顺序必须是：readDataToEndOfFile()（阻塞到 EOF）→ waitUntilExit()。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()

        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let status = (
            onAC: output.contains("AC Power"),
            // 快充满时 macOS 输出 "finishing charge"（收尾涓流仍在充，菜单栏仍显示充电），
            // 该串不含独立词 "charging"，需单独计入充电；纯 "charged"（已充满）不算充电。
            charging: (output.contains("charging") && !output.contains("discharging"))
                        || output.contains("finishing charge"),
            charged: output.contains("charged") || output.contains("finishing charge")
        )

        // 缓存写入：短临界区。
        lock.lock()
        pmsetCache = status
        pmsetCacheTime = now
        lock.unlock()
        return status
    }

    /// 用 IOPS 官方电源源判定是否在充电（与系统菜单栏电池图标一致，插拔即时）。
    /// 兼容 CFBoolean（桥接为 Bool）与 CFNumber（0/1）两种取值形式。
    private static func ioPSIsCharging() -> Bool? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any],
                let value = desc[kIOPSIsChargingKey] else { continue }
            if let flag = value as? Bool { return flag }
            if let n = value as? NSNumber { return n.boolValue }
        }
        return nil
    }

    /// 读取 AppleSmartBattery 的完整属性字典；失败返回 nil（调用方据此重建句柄重试）。
    private static func readProperties(_ service: io_service_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
            == kIOReturnSuccess,
            let dict = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// 获取缓存的 AppleSmartBattery 服务句柄；首次调用时匹配一次并复用。
    private static func currentService() -> io_service_t {
        if cachedService == 0 {
            cachedService = IOServiceGetMatchingService(kIOMainPortDefault,
                                                        IOServiceMatching("AppleSmartBattery"))
        }
        return cachedService
    }

    /// 释放无效句柄并重新匹配，返回新句柄（失败为 0）。
    private static func rebuildService() -> io_service_t {
        if cachedService != 0 { IOObjectRelease(cachedService); cachedService = 0 }
        cachedService = IOServiceGetMatchingService(kIOMainPortDefault,
                                                    IOServiceMatching("AppleSmartBattery"))
        return cachedService
    }

    /// 从注册表属性字典中尽量提取 Int（兼容 CFNumber 与 CFString 两种表示）。
    private static func intValue(_ value: Any?) -> Int {
        guard let value else { return 0 }
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }
}