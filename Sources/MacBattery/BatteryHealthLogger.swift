import Foundation
import Combine

/// 电池健康信息的一个采样点（内存态）。
struct BatteryHealthSample: Equatable {
    var t: Date
    var maxCapacity: Int
    var designCapacity: Int
    var healthPercent: Double
    var cycleCount: Int
    /// 采样时刻的电量百分比（0...100），用于计算实时容量曲线（最大容量 × 电量）。
    var levelPercent: Int
}

/// 电池健康日志中枢：健康数据（最大容量 / 设计容量 / 健康度 / 循环次数）变化极慢，
/// 因此以较低的频率采样、且仅在数值发生变化时才追加并落盘，避免大量平直重复点。
/// 独立于功率日志（PowerLogger）持久化到 `battery_health_log.csv`，
/// 图表打开时回填最近一段历史。随应用常驻运行，即使不开图表也能持续积累历史。
@MainActor
final class BatteryHealthLogger: ObservableObject {

    /// 内存保留的样本上限。健康值变化极慢（日级），保留最近约一年即可。
    static let memoryCapacity = 2000

    /// 图表打开时从磁盘回填的历史点数量上限（一年内足够）。
    static let historyBackfill = 2000

    /// 采样间隔：每 60s 尝试读取一次，未变化则不落盘。
    static let sampleInterval: TimeInterval = 60

    /// 基线留档间隔：即使健康值未变化，每隔该时长也强制记录一条，避免长时间无历史点。
    static let baselineInterval: TimeInterval = 6 * 3600

    /// 按时间升序的健康样本缓冲（主线程访问）。
    @Published private(set) var samples: [BatteryHealthSample] = []

    /// 磁盘读写（所有 IO 方法均非隔离，可安全在后台调用）。
    private nonisolated let store = BatteryHealthLogStore()

    private var timer: Timer?

    /// 上一次成功写入的值；用于判断健康值是否发生变化。
    private var lastRecorded: BatteryHealthSample?

    /// 代际计数：每次重置 +1，用于丢弃重置前已发出的异步磁盘回填，避免旧历史被塞回内存。
    private var generation = 0

    init() {}

    /// 启动日志：先回填磁盘历史，再每 60s 采样一次（值变化才落盘）。
    func start() {
        backfillHistory()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        // 启动即强制采样一次：无论健康值是否变化都留档一条基线，
        // 使多次运行也能积累时间上分散的历史点（健康值长期不变时默认策略会一直跳过）。
        sample(force: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 立即采样一次并强制落盘（供打开健康窗口等时机调用），保证每次打开都留档、曲线始终可见。
    func recordNow() {
        sample(force: true)
    }

    /// 重置：清空内存缓冲与磁盘 CSV，历史从零开始（不可恢复）。
    func reset() {
        generation += 1
        if !samples.isEmpty { objectWillChange.send() }
        samples.removeAll()
        lastRecorded = nil
        store.clearDisk()
    }

    // MARK: - 采样

    /// 读取一次电池健康值并决定是否落盘。
    /// - force：为 true 时无条件记录本次（用于启动 / 打开窗口等观感至关重要的时机）。
    /// - 否则仅当任一字段相对上一条有变化，或距上一条已超过基线间隔时才记录。
    private func sample(force: Bool = false) {
        guard let health = BatteryReader.health() else { return }
        let now = BatteryHealthSample(
            t: Date(),
            maxCapacity: health.maxCapacity,
            designCapacity: health.designCapacity,
            healthPercent: health.healthPercent,
            cycleCount: health.cycleCount,
            levelPercent: BatteryReader.level()
        )
        if !force, let last = lastRecorded {
            // 1) 健康值发生任何变化 → 必须记录；
            // 2) 距上次记录已超过基线间隔 → 即使未变化也强制留档，历史不空洞。
            let changed = last.maxCapacity != now.maxCapacity
                || last.designCapacity != now.designCapacity
                || abs(last.healthPercent - now.healthPercent) >= 1e-9
                || last.cycleCount != now.cycleCount
            let staleBaseline = now.t.timeIntervalSince(last.t) >= Self.baselineInterval
            if !changed && !staleBaseline { return }
        }
        append(now)
    }

    private func append(_ f: BatteryHealthSample) {
        if samples.count + 1 > Self.memoryCapacity {
            objectWillChange.send()
            samples.removeFirst(samples.count + 1 - Self.memoryCapacity)
        }
        objectWillChange.send()
        samples.append(f)
        lastRecorded = f
        store.write([f])
    }

    /// 从磁盘回填历史，仅在缓冲为空时执行。
    private func backfillHistory() {
        guard samples.isEmpty else { return }
        let gen = generation
        store.readRecent(limit: Self.historyBackfill) { [weak self] history in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                let merged = self.merge(history: history, new: self.samples)
                guard merged != self.samples else { return }
                self.samples = merged
                self.lastRecorded = self.samples.last
            }
        }
    }

    /// 把磁盘历史与内存中的新采样按时间升序合并、去重，并裁剪到内存容量上限。
    /// 启动时 `sample(force: true)` 会同步先写入内存新点，因此回填不能因缓冲非空而丢弃
    /// 磁盘历史，否则每次启动都只有启动瞬间那 1 个点、健康曲线永远空白。
    private func merge(history: [BatteryHealthSample], new: [BatteryHealthSample]) -> [BatteryHealthSample] {
        let pooled = (history + new).sorted { $0.t < $1.t }
        var deduped: [BatteryHealthSample] = []
        for s in pooled {
            if let last = deduped.last, last.t == s.t {
                deduped[deduped.count - 1] = s
            } else {
                deduped.append(s)
            }
        }
        if deduped.count > Self.memoryCapacity {
            deduped.removeFirst(deduped.count - Self.memoryCapacity)
        }
        return deduped
    }
}

/// 非隔离的 CSV 持久化（在后台串行队列使用，全部 self-contained）。
private final class BatteryHealthLogStore {

    private let ioQueue = DispatchQueue(label: "MacBattery.Health.io", qos: .utility)
    private var handle: FileHandle?
    private var headerWritten = false
    private let header = "epoch,maxCapacity,designCapacity,healthPercent,cycleCount,levelPercent\n"

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("MacBattery", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("battery_health_log.csv")
    }

    /// 在 ioQueue 上追加一批样本写入 CSV（线程安全）。
    func write(_ batch: [BatteryHealthSample]) {
        guard !batch.isEmpty else { return }
        ioQueue.async { [self] in self.writeSamples(batch) }
    }

    /// 清空磁盘历史：关闭句柄、删除 CSV（下次写入会重建文件并重新写表头）。
    func clearDisk() {
        ioQueue.async { [self] in
            if let h = handle { try? h.close() }
            handle = nil
            headerWritten = false
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// 读取最近若干历史记录，完成后在调用方提供的回调里返回（升序）。
    func readRecent(limit: Int, completion: @escaping ([BatteryHealthSample]) -> Void) {
        ioQueue.async { [self] in
            let result = self.readRecentHistory(limit: limit)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: 写

    private func writeSamples(_ batch: [BatteryHealthSample]) {
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

    private func csvLine(_ s: BatteryHealthSample) -> String {
        "\(s.t.timeIntervalSince1970),\(s.maxCapacity),\(s.designCapacity),"
            + "\(s.healthPercent),\(s.cycleCount),\(s.levelPercent)\n"
    }

    private func fileHandle() -> FileHandle? {
        if let h = handle { return h }
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
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
    /// 逻辑与 PowerLogStore.readRecentHistory 一致（分块倒读避免全文件加载）。
    private func readRecentHistory(limit: Int) -> [BatteryHealthSample] {
        let url = fileURL
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attr[.size] as? NSNumber)?.intValue, size > 0 else { return [] }

        var result: [BatteryHealthSample] = []
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
            guard var text = String(data: data, encoding: .utf8) else { break }
            text += leftover
            var lines: [Substring] = text.split(separator: "\n")
            if offset > 0 && !lines.isEmpty {
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
        result = result.filter { $0.t != .distantPast }
        return result.sorted { $0.t < $1.t }
    }

    private func parseCSVLine(_ line: Substring) -> BatteryHealthSample? {
        let parts = line.split(separator: ",", omittingEmptySubsequences: false)
        // 兼容旧 5 列文件（无 levelPercent）：6 列及以上才读取，缺失记为 -1 表示未知。
        guard parts.count >= 5,
              let epochString = parts[0].split(separator: ".").first,
              let epoch = Double(epochString) else { return nil }
        // 过滤表头 / 明显早于 2000 年的无效行。
        if epoch < 946684800 {
            return nil
        }
        let level = parts.count >= 6 ? (Int(parts[5]) ?? -1) : -1
        return BatteryHealthSample(
            t: Date(timeIntervalSince1970: epoch),
            maxCapacity: Int(parts[1]) ?? 0,
            designCapacity: Int(parts[2]) ?? 0,
            healthPercent: Double(parts[3]) ?? 0,
            cycleCount: Int(parts[4]) ?? 0,
            levelPercent: level
        )
    }
}