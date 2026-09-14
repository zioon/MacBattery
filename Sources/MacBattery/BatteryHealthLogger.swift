import Foundation
import Combine

/// 电池健康信息的一个采样点（内存态）。
struct BatteryHealthSample {
    var t: Date
    var maxCapacity: Int
    var designCapacity: Int
    var healthPercent: Double
    var cycleCount: Int
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

    init() {}

    /// 启动日志：先回填磁盘历史，再每 60s 采样一次（值变化才落盘）。
    func start() {
        backfillHistory()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        // 启动即采样一次，尽快记录当前健康值。
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 立即采样一次并落盘（供打开健康窗口等时机调用），确保当前值马上可见。
    func recordNow() {
        sample()
    }

    // MARK: - 采样

    /// 读取一次电池健康值；任一字段相对上一条有变化，或距上一条已超过基线间隔时追加并落盘。
    private func sample() {
        guard let health = BatteryReader.health() else { return }
        let now = BatteryHealthSample(
            t: Date(),
            maxCapacity: health.maxCapacity,
            designCapacity: health.designCapacity,
            healthPercent: health.healthPercent,
            cycleCount: health.cycleCount
        )
        if let last = lastRecorded {
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
        store.readRecent(limit: Self.historyBackfill) { [weak self] history in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 回填完成前若已有新采样写入缓冲，则保留内存中的最新数据、不覆盖，
                // 避免异步回填把启动瞬间采到的点冲掉导致图表空白。
                guard self.samples.isEmpty else { return }
                self.samples = history
                self.lastRecorded = history.last
            }
        }
    }
}

/// 非隔离的 CSV 持久化（在后台串行队列使用，全部 self-contained）。
private final class BatteryHealthLogStore {

    private let ioQueue = DispatchQueue(label: "MacBattery.Health.io", qos: .utility)
    private var handle: FileHandle?
    private var headerWritten = false
    private let header = "epoch,maxCapacity,designCapacity,healthPercent,cycleCount\n"

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
            + "\(s.healthPercent),\(s.cycleCount)\n"
    }

    private func fileHandle() -> FileHandle? {
        if let h = handle { return h }
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        return handle
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
        guard parts.count >= 5,
              let epochString = parts[0].split(separator: ".").first,
              let epoch = Double(epochString) else { return nil }
        // 过滤表头 / 明显早于 2000 年的无效行。
        if epoch < 946684800 {
            return nil
        }
        return BatteryHealthSample(
            t: Date(timeIntervalSince1970: epoch),
            maxCapacity: Int(parts[1]) ?? 0,
            designCapacity: Int(parts[2]) ?? 0,
            healthPercent: Double(parts[3]) ?? 0,
            cycleCount: Int(parts[4]) ?? 0
        )
    }
}