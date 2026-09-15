import Foundation
import Combine
import os

/// 一次采样记录的完整数据点（内存态）。
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
}

/// 日志中枢：把每次采样追加进内存环形缓冲（供图表实时使用），
/// 并异步持久化到 CSV（`~/Library/Application Support/MacBattery/power_log.csv`），
/// 跨会话留存历史，图表打开时回填最近一段历史。
///
/// 主线程负责缓冲与发布（samples / append）；磁盘读写委托给非隔离的
/// `PowerLogStore`，在后台串行队列执行，不阻塞 UI。
@MainActor
final class PowerLogger: ObservableObject {

    /// 内存保留的样本上限。按 0.5s 一次采样计算，约等于最近 24 小时：
    /// 24h × 7200 次/h ≈ 172800，留一点余量取 200000。
    static let memoryCapacity = 200_000

    /// 图表打开时从磁盘回填的历史点数量上限。
    static let historyBackfill = 40_000

    /// 按时间升序的样本缓冲（主线程访问）。
    @Published private(set) var samples: [PowerSample] = []

    /// 磁盘读写（所有 IO 方法均非隔离，可安全在后台调用）。
    private nonisolated let store = PowerLogStore()

    private var timer: Timer?
    /// 待落盘的样本（每次 flush 清空）。
    private var pending: [PowerSample] = []

    /// 代际计数：每次重置 +1，用于丢弃重置前已发出的异步磁盘回填，避免旧历史被塞回内存。
    private var generation = 0

    init() {}

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
    func append(_ f: PowerSample) {
        if samples.count + 1 > Self.memoryCapacity {
            // 缓冲已满才裁剪（约每容量次触发一次，命中率很低）。
            objectWillChange.send()
            samples.removeFirst(samples.count + 1 - Self.memoryCapacity)
        }
        objectWillChange.send()
        samples.append(f)
        pending.append(f)
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
                self.objectWillChange.send()
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
    private let header = "epoch,batteryPercent,isCharging,chargingWatts,chargingVoltage,chargingCurrent,cpuUsage,memoryUsage,systemWatts\n"

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("MacBattery", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("power_log.csv")
    }

    /// 在 ioQueue 上把一批样本追加写入 CSV（线程安全）。
    func write(_ batch: [PowerSample]) {
        guard !batch.isEmpty else { return }
        ioQueue.async { [self] in self.writeSamples(batch) }
    }

    /// 清空磁盘历史：关闭句柄、删除 CSV（下次写入会重建文件并重新写表头）。
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
            let url = fileURL
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

    /// 读取最近若干历史记录，完成后在调用方提供的回调里返回（升序）。
    func readRecent(limit: Int, completion: @escaping ([PowerSample]) -> Void) {
        ioQueue.async { [self] in
            let result = self.readRecentHistory(limit: limit)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: 写

    private func writeSamples(_ batch: [PowerSample]) {
        guard let h = fileHandle() else { return }
        if !headerWritten {
            if let d = header.data(using: .utf8) { h.write(d) }
            headerWritten = true
        }
        var buf = Data()
        for s in batch {
            buf.append(csvLine(s).data(using: .utf8) ?? Data())
            if buf.count > 1 << 16 { h.write(buf); buf = Data() }
        }
        if !buf.isEmpty { h.write(buf) }
    }

    private func csvLine(_ s: PowerSample) -> String {
        "\(s.t.timeIntervalSince1970),\(s.batteryPercent),\(s.isCharging ? 1 : 0),"
            + "\(s.chargingWatts),\(s.chargingVoltage),\(s.chargingCurrent),"
            + "\(s.cpuUsage),\(s.memoryUsage),\(s.systemWatts)\n"
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
    private func readRecentHistory(limit: Int) -> [PowerSample] {
        let url = fileURL
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attr[.size] as? NSNumber)?.intValue, size > 0 else { return [] }

        var result: [PowerSample] = []
        let chunk = 1 << 20
        var offset = size
        var readSoFar = 0
        var leftover: Substring = ""

        while offset > 0 && result.count < limit && readSoFar < 48 << 20 {
            let len = min(chunk, offset)
            offset -= len
            readSoFar += len
            guard let fh = try? FileHandle(forReadingFrom: url) else { break }
            defer { try? fh.close() }
            do { try fh.seek(toOffset: UInt64(offset)) } catch { break }
            let data = (try? fh.read(upToCount: len)) ?? Data()
            // 用 String(decoding:as:) 而非 String(data:encoding:)：后者在块边界落在
            // 多字节字符中间时返回 nil，会 break 掉**整段**历史（与 1.1.5/1.1.9 反复出现的
            // "曲线空白"同源）。前者永不失败，非法字节替换为 U+FFFD，最多影响该行
            //（解析失败已由 parseCSVLine 返回 nil 处理）。
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
                if let s = parseCSVLine(line) {
                    result.append(s)
                    if result.count >= limit { break }
                }
            }
        }
        // 因读取字节上限而提前结束（而非读完全部或凑够 limit）：历史文件过大，
        // 更早的数据被截断。此前静默发生，现在留下痕迹。
        if offset > 0 && result.count < limit {
            Self.logger.warning("历史文件过大，回填被截断: 剩余 \(offset, privacy: .public) 字节未读")
        }
        // 过滤表头并升序。
        result = result.filter { $0.t != .distantPast }
        return result.sorted { $0.t < $1.t }
    }

    private func parseCSVLine(_ line: Substring) -> PowerSample? {
        let parts = line.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 9,
              let epochString = parts[0].split(separator: ".").first,
              let epoch = Double(epochString) else { return nil }
        // 过滤表头（首列为非时间戳文本导致 epoch 解析失败时已返回 nil；
        // 这里再把明显早于 2000 年的值标记为无效行）。
        if epoch < 946684800 {
            return PowerSample(t: .distantPast, batteryPercent: 0, isCharging: false,
                               chargingWatts: 0, chargingVoltage: 0, chargingCurrent: 0,
                               cpuUsage: 0, memoryUsage: 0, systemWatts: 0)
        }
        return PowerSample(
            t: Date(timeIntervalSince1970: epoch),
            batteryPercent: Int(parts[1]) ?? 0,
            isCharging: (parts[2] == "1"),
            chargingWatts: Double(parts[3]) ?? 0,
            chargingVoltage: Double(parts[4]) ?? 0,
            chargingCurrent: Double(parts[5]) ?? 0,
            cpuUsage: Double(parts[6]) ?? 0,
            memoryUsage: Double(parts[7]) ?? 0,
            systemWatts: Double(parts[8]) ?? 0
        )
    }
}