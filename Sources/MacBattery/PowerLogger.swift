import Foundation
import Combine
import os
import MacBatteryCore

/// 一次采样记录的完整数据点（内存态）。
///
/// - Note: 内存里保留**全精度**采样；只有**落盘**时才定点化（`PowerSampleRecord`）。
///   图表的实时观感不受压缩影响。
struct PowerSample {
    var t: Date
    var batteryPercent: Int
    var isCharging: Bool
    var chargingWatts: Double
    var chargingVoltage: Double   // 伏特
    var chargingCurrent: Double   // 安培
    var cpuUsage: Double          // 0...1
    var memoryUsage: Double       // 0...1
    var systemWatts: Double

    /// 定点化后的落盘形态。
    init(record: PowerSampleRecord) {
        t = record.timestamp
        batteryPercent = record.batteryPercent
        isCharging = record.isCharging
        chargingWatts = Double(record.chargingMilliWatts) / 1000
        chargingVoltage = Double(record.chargingMilliVolts) / 1000
        chargingCurrent = Double(record.chargingMilliAmps) / 1000
        cpuUsage = Double(record.cpuPercent) / 100
        memoryUsage = Double(record.memoryPercent) / 100
        systemWatts = Double(record.systemMilliWatts) / 1000
    }

    /// 定点化后的落盘形态。
    var record: PowerSampleRecord {
        PowerSampleRecord(t: t,
                          batteryPercent: batteryPercent,
                          isCharging: isCharging,
                          chargingWatts: chargingWatts,
                          chargingVoltage: chargingVoltage,
                          chargingCurrent: chargingCurrent,
                          cpuUsage: cpuUsage,
                          memoryUsage: memoryUsage,
                          systemWatts: systemWatts)
    }
}

/// 日志中枢：把每次采样追加进内存环形缓冲（供图表实时使用），
/// 并异步持久化到 CSV（`~/Library/Application Support/MacBattery/power_log_v2.csv`），
/// 跨会话留存历史，图表打开时回填最近一段历史。
///
/// **内存与磁盘解耦**：内存是全量、全精度的 0.5s 采样（图表观感不受影响）；
/// 落盘前先过 `PowerLogGate` 的变化门控 + 定点化，稳态下写入率降到 1/60s。
///
/// 主线程负责缓冲与发布（samples / append）；磁盘读写委托给非隔离的
/// `PowerLogStore`，在后台串行队列执行，不阻塞 UI。
@MainActor
final class PowerLogger: ObservableObject {

    /// 内存保留的样本上限。按 0.5s 一次采样计算，约等于最近 24 小时：
    /// 24h × 7200 次/h ≈ 172800，留一点余量取 200000。
    static let memoryCapacity = 200_000

    /// 图表打开时从磁盘回填的历史点数量上限。
    ///
    /// 落盘密度已降到约 1/60s（稳态），40000 点 ≈ **27 天**历史，
    /// 而 v1 时代同样 40000 点只覆盖不到 30 分钟。
    static let historyBackfill = 40_000

    /// 按时间升序的样本缓冲（主线程访问）。
    @Published private(set) var samples: [PowerSample] = []

    /// 磁盘读写（所有 IO 方法均非隔离，可安全在后台调用）。
    private nonisolated let store = PowerLogStore()

    private var timer: Timer?
    /// 待落盘的样本（每次 flush 清空）。已经过门控筛选 —— 这里存的是**定点记录**。
    private var pending: [PowerSampleRecord] = []
    /// 上一条**已落盘**的记录：变化门控的基准。首次 / 重置后为 nil。
    private var lastPersisted: PowerSampleRecord?
    /// 落盘门控（纯逻辑在 MacBatteryCore，可单测）。
    private let gate: PowerLogGate

    /// 代际计数：每次重置 +1，用于丢弃重置前已发出的异步磁盘回填，避免旧历史被塞回内存。
    private var generation = 0

    init(gate: PowerLogGate = .default) {
        self.gate = gate
    }

    /// 启动日志：先回填磁盘历史，再每 1s 合并落盘一次（降低 IO 次数）。
    func start() {
        backfillHistory()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flushPending() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        flushPending()
    }

    // MARK: - 追加采样

    /// 追加一个采样点（由 PowerMonitor 在每次采样完成后调用，主线程）。
    /// 只就地追加单个元素并手动发布，避免每次 O(n) 复制整个缓冲导致主线程被打折。
    ///
    /// **内存与磁盘解耦**：每一次采样都进 `samples`（图表要全量、全精度）；
    /// 但只有通过 `gate.shouldPersist` 的才进 `pending` 落盘。
    /// 稳态下 0.5s 一采绝大多数是重复值，因此实际写入率降到 1/60s。
    func append(_ f: PowerSample) {
        if samples.count + 1 > Self.memoryCapacity {
            // 缓冲已满才裁剪（约每容量次触发一次，命中率很低）。
            objectWillChange.send()
            samples.removeFirst(samples.count + 1 - Self.memoryCapacity)
        }
        objectWillChange.send()
        samples.append(f)

        let record = f.record
        guard gate.shouldPersist(previous: lastPersisted, current: record) else { return }
        lastPersisted = record
        pending.append(record)
    }

    // MARK: - 落盘

    private func flushPending() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        store.write(batch)
    }
    /// 从磁盘回填历史，使启动后也能看到趋势。仅在缓冲为空时执行。
    private func backfillHistory() {
        guard samples.isEmpty else { return }
        let gen = generation
        store.readRecent(limit: Self.historyBackfill) { [weak self] history in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                // 不能直接用 history 覆盖 samples：回填是异步的，它抵达时内存里
                // 可能已经有新追加的采样，直接覆盖会静默丢弃它们（v1.1.9 只在健康日志
                // 修过，功率日志此处漏修）。与内存新采样合并才能保证两侧数据都不丢。
                let merged = mergedByTimestamp(history: history,
                                               new: self.samples,
                                               timestamp: { $0.t },
                                               capacity: Self.memoryCapacity)
                guard merged.count != self.samples.count
                        || merged.last?.t != self.samples.last?.t else { return }
                // samples 是 @Published，赋值本身就会发 objectWillChange，无需手动再发一次。
                self.samples = merged
            }
        }
    }

    /// 重置：清空内存缓冲与磁盘 CSV，历史从零开始（不可恢复）。
    func reset() {
        generation += 1
        if !samples.isEmpty { objectWillChange.send() }
        samples.removeAll()
        pending.removeAll()
        // 门控基准必须一并清掉：留着上一条记录会让重置后的首条采样被误判为「未变化」，
        // 于是要等到基线间隔才写下第一条。
        lastPersisted = nil
        store.clearDisk()
    }
}

/// 非隔离的 CSV 持久化（在后台串行队列使用，全部 self-contained）。
private final class PowerLogStore {

    /// IO 失败此前全部被 `try?` 静默吞掉，历史丢失时无任何痕迹；改为记录到系统日志。
    private static let logger = Logger(subsystem: "com.zioon.macbattery", category: "io")

    private let ioQueue = DispatchQueue(label: "MacBattery.Logger.io", qos: .utility)
    private var handle: FileHandle?
    private var headerWritten = false

    private func logFolder() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("MacBattery", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// 当前写入的 v2 定点格式文件。
    private var fileURL: URL {
        logFolder().appendingPathComponent("power_log_v2.csv")
    }

    /// 升级前的 v1 全精度文件（只读，不再写入）。历史必须保留 —— 用户升级后
    /// 不该突然丢掉已有的曲线。
    private var legacyFileURL: URL {
        logFolder().appendingPathComponent("power_log.csv")
    }

    /// 在 ioQueue 上把一批样本追加写入 CSV（线程安全）。
    func write(_ batch: [PowerSampleRecord]) {
        guard !batch.isEmpty else { return }
        ioQueue.async { [self] in self.writeSamples(batch) }
    }

    /// 清空磁盘历史：关闭句柄、删除 CSV（下次写入会重建文件并重新写表头）。
    /// v1 遗留文件一并删除 —— 「重置」的用户语义就是「历史从零开始」。
    func clearDisk() {
        ioQueue.async { [self] in
            if let h = handle {
                do {
                    try h.close()
                } catch {
                    Self.logger.error("关闭 CSV 写句柄失败: \(error.localizedDescription, privacy: .public)")
                }
            }
            handle = nil
            headerWritten = false
            for url in [self.fileURL, self.legacyFileURL] {
                // 文件本就不存在时视为已达成目标，不记错误，避免 reset 时刷无意义日志。
                if FileManager.default.fileExists(atPath: url.path) {
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch {
                        Self.logger.error("删除 CSV 失败: \(url.path, privacy: .public), \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    /// 读取最近若干历史记录，完成后在调用方提供的回调里返回（升序）。
    func readRecent(limit: Int, completion: @escaping ([PowerSample]) -> Void) {
        ioQueue.async { [self] in
            let result = self.readRecentHistory(limit: limit)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: 写

    private func writeSamples(_ batch: [PowerSampleRecord]) {
        guard let h = fileHandle() else { return }
        if !headerWritten {
            if let d = PowerLogEncoding.headerV2.data(using: .utf8) { h.write(d) }
            headerWritten = true
        }
        var buf = Data()
        for s in batch {
            buf.append(PowerLogEncoding.line(s).data(using: .utf8) ?? Data())
            if buf.count > 1 << 16 { h.write(buf); buf = Data() }
        }
        if !buf.isEmpty { h.write(buf) }
    }

    private func fileHandle() -> FileHandle? {
        if let h = handle { return h }
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let created = FileManager.default.createFile(atPath: url.path, contents: nil)
            if !created {
                Self.logger.error("创建 CSV 失败: \(url.path, privacy: .public)")
            }
        }
        let opened: FileHandle
        do {
            opened = try FileHandle(forWritingTo: url)
        } catch {
            Self.logger.error("打开 CSV 写句柄失败: \(url.path, privacy: .public), \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let h = opened
        // 关键：FileHandle(forWritingTo:) 的文件指针在开头，这里移动到文件末尾，
        // 以追加方式写入，避免应用重启后新数据从头部覆盖旧历史。
        try? h.seekToEnd()
        handle = h
        // 文件已存在且非空时，表头早已写过，不再重复写入。
        if let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = (attr[.size] as? NSNumber)?.intValue, size > 0 {
            headerWritten = true
        }
        return h
    }

    // MARK: 读

    /// 从 CSV 尾部倒序读取若干完整行并解析，返回按时间升序的样本。
    ///
    /// 读**两个**文件并按时间合并：当前 v2（定点）+ 升级前的 v1（全精度 Double）。
    /// 格式版本靠文件名区分而非逐列启发式，理由见 `PowerLogEncoding` 的注释。
    private func readRecentHistory(limit: Int) -> [PowerSample] {
        // 字节预算在两个文件间分摊，各占一半：单个文件仍保留分块倒读的短路能力，
        // 又不会让庞大的 v1 遗留文件把 v2 的读取额度吃光。
        let perFileLimit = max(1, limit / 2)
        let v2 = readTail(fileURL: fileURL, limit: perFileLimit, parse: PowerLogEncoding.parseV2)
        let v1 = readTail(fileURL: legacyFileURL, limit: perFileLimit, parse: PowerLogEncoding.parseV1)

        // 同一时刻可能同时存在于 v1 与 v2（升级边界附近），按时间戳去重：
        // 时间戳相同时 v2 覆盖 v1（定点精度已收敛，且它是同一事实的最终形态）。
        var byTime: [Int: PowerSampleRecord] = [:]
        for r in v1 { byTime[r.epochMilliseconds] = r }
        for r in v2 { byTime[r.epochMilliseconds] = r }

        return byTime.values
            .sorted { $0.epochMilliseconds < $1.epochMilliseconds }
            .suffix(limit)
            .map { PowerSample(record: $0) }
    }

    /// 从单个 CSV 尾部倒序读取若干完整行并解析（升序）。
    ///
    /// - Parameters:
    ///   - parse: 行解析器（v1 / v2 各一个）。返回 nil 的行（残行、表头、格式不符）被跳过。
    private func readTail(fileURL: URL,
                         limit: Int,
                         parse: (Substring) -> PowerSampleRecord?) -> [PowerSampleRecord] {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attr[.size] as? NSNumber)?.intValue, size > 0 else { return [] }

        var result: [PowerSampleRecord] = []
        let chunk = 1 << 20
        var offset = size
        var readSoFar = 0
        var leftover: Substring = ""
        // 区分「读取失败」与「真的因文件过大被截断」：原先两者都落在同一条
        // "文件过大" 警告里，把 IO 故障误报成了正常截断。
        var readFailed = false

        while offset > 0 && result.count < limit && readSoFar < 48 << 20 {
            let len = min(chunk, offset)
            offset -= len
            readSoFar += len
            let fh: FileHandle
            do {
                fh = try FileHandle(forReadingFrom: fileURL)
            } catch {
                Self.logger.error("打开 CSV 读句柄失败: \(fileURL.path, privacy: .public), \(error.localizedDescription, privacy: .public)")
                readFailed = true
                break
            }
            defer { try? fh.close() }
            do { try fh.seek(toOffset: UInt64(offset)) } catch {
                Self.logger.error("CSV 读定位失败: \(fileURL.path, privacy: .public), \(error.localizedDescription, privacy: .public)")
                readFailed = true
                break
            }
            let data: Data
            do {
                data = try fh.read(upToCount: len) ?? Data()
            } catch {
                Self.logger.error("CSV 读取失败: \(fileURL.path, privacy: .public), \(error.localizedDescription, privacy: .public)")
                readFailed = true
                break
            }
            // 用 String(decoding:as:) 而非 String(data:encoding:)：后者在块边界落在
            // 多字节字符中间时返回 nil，会 break 掉**整段**历史（与 1.1.5/1.1.9 反复出现的
            // "曲线空白"同源）。前者永不失败，非法字节替换为 U+FFFD，最多影响该行
            //（解析失败已由 parse 返回 nil 处理）。
            var text = String(decoding: data, as: UTF8.self)
            text += leftover
            var lines: [Substring] = text.split(separator: "\n")
            if offset > 0 && !lines.isEmpty {
                // 非首块：首行不完整，丢弃。
                leftover = lines.first ?? ""
                lines = Array(lines.dropFirst())
            } else {
                leftover = ""
            }
            for line in lines.reversed() {
                if let s = parse(line) {
                    result.append(s)
                    if result.count >= limit { break }
                }
            }
        }
        // 读取失败 与 真正因 48MB 字节上限被截断，分别留下不同的痕迹。
        if readFailed {
            Self.logger.warning("历史回填因读取失败提前结束，本次回填可能不完整")
        } else if readSoFar >= 48 << 20 && offset > 0 {
            Self.logger.warning("历史文件过大（超过 48MB），回填被截断: \(fileURL.lastPathComponent, privacy: .public) 剩余 \(offset, privacy: .public) 字节未读")
        }
        return result.sorted { $0.epochMilliseconds < $1.epochMilliseconds }
    }
}