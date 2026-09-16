import Foundation
import Combine
import os

/// 电池健康信息的一个采样点（内存态）。
struct BatteryHealthSample: Equatable {
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

    /// 健康采样专用串行队列：IOKit 读取（BatteryReader.health / level）不占主线程，
    /// 也不与 0.5s 的功率采样队列争抢。只在这里执行读取，结果回主线程应用。
    private let readQueue = DispatchQueue(label: "MacBattery.health.read", qos: .utility)

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
        // 注意：`sample()` 现在是异步的（硬件读取在 readQueue 上），
        // 因此这个启动点与下面的磁盘回填的**到达顺序不再确定**，见 backfillHistory 的注释。
        sample(force: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 立即采样一次并强制落盘（供打开健康窗口等时机调用），保证每次打开都留档、曲线始终可见。
    /// ⚠️ 取舍：硬件读取已移到 readQueue，本方法**不再同步完成** —— 打开健康窗口时
    /// 采样会延迟约毫秒级才落盘。可接受的代价（换来主线程不再做 IOKit 读取）。
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

    /// 触发一次健康采样：硬件读取（IOKit）在 `readQueue` 上执行，只把"应用结果"留在主线程。
    /// - force：为 true 时无条件记录本次（用于启动 / 打开窗口等观感至关重要的时机）。
    /// - 否则仅当任一字段相对上一条有变化，或距上一条已超过基线间隔时才记录。
    ///
    /// 三个调用点（启动首拍 / 60s 定时器 / `recordNow()`）全在主线程，
    /// 其中 60s 那条会长期、反复地与 0.5s 功率采样队列重叠，因此读取必须移出主线程。
    private func sample(force: Bool = false) {
        // 在主线程快照代际（`generation` 是 @MainActor 状态），带进后台、再带回主线程校验。
        // `gen` 是 Int（值类型，Sendable），捕获进后台闭包安全。
        let gen = generation
        readQueue.async { [weak self] in
            // ⚠️ 护栏：dispatchPrecondition 基于 precondition，**发布版（-O）同样会崩溃**
            //（只有 -Ounchecked 才移除）。新增硬件读取入口前务必先确认它的调用队列。
            dispatchPrecondition(condition: .notOnQueue(.main))
            guard let health = BatteryReader.health() else { return }
            Task { @MainActor [weak self] in
                // 期间若发生重置（reset() 已把 generation +1），丢弃这次在途采样 ——
                // 否则会把陈旧点 append 回内存，并在 clearDisk() 之后再次落盘
                //（用户可见后果：清空后曲线立刻回潮一个点）。
                // 校验必须在这里做：generation 是主线程状态。
                guard let self, self.generation == gen else { return }
                self.applySample(health: health, force: force)
            }
        }
    }

    /// 在主线程应用一次健康采样结果：构造样本 → 判定是否落盘 → 追加。
    /// `BatteryReader.BatteryHealth` 是纯值 struct（仅 Int / Double 字段），跨线程传递安全。
    @MainActor
    private func applySample(health: BatteryReader.BatteryHealth, force: Bool) {
        let now = BatteryHealthSample(
            t: Date(),
            maxCapacity: health.maxCapacity,
            designCapacity: health.designCapacity,
            healthPercent: health.healthPercent,
            cycleCount: health.cycleCount
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
    ///
    /// **时序分析（U-01 第 2 步把采样改成异步后仍然成立）**：
    /// `start()` 先调本方法、再调 `sample(force: true)`。改动前启动点是**同步**写进内存的，
    /// 必定早于异步回填到达；改动后启动点要在 readQueue 上读一轮才回主线程追加，
    /// 于是回填与启动点的到达顺序变得不确定。两种顺序都正确：
    /// - 回填先到：`samples` 仍为空 → `mergedByTimestamp(history, [])` = 历史本身，赋值；
    ///   随后 `append()` 把启动点追加到末尾（时间戳最新，仍保持升序）。
    /// - 启动点先到：`samples == [启动点]` → 合并历史与该点，两者都在，按时间升序。
    /// 这正是 v1.1.9 引入 merge 的原因（不能因缓冲非空而丢弃磁盘历史），
    /// 现在该逻辑提升到共用的 `mergedByTimestamp`，对两种顺序一视同仁。
    ///
    /// 另外两处守卫不受时序影响：
    /// - `guard samples.isEmpty` 是在**调用时同步**求值的（此刻还没有任何异步追加发生），
    ///   所以改动后它依然为真、回填照常发起；
    /// - `generation` 在调用时快照、在回调里比对，用于丢弃 reset 之前发出的回填，
    ///   与到达顺序无关，仍然成立。
    private func backfillHistory() {
        guard samples.isEmpty else { return }
        let gen = generation
        store.readRecent(limit: Self.historyBackfill) { [weak self] history in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                let merged = mergedByTimestamp(history: history,
                                               new: self.samples,
                                               timestamp: { $0.t },
                                               capacity: Self.memoryCapacity)
                guard merged != self.samples else { return }
                self.samples = merged
                self.lastRecorded = self.samples.last
            }
        }
    }
}

/// 非隔离的 CSV 持久化（在后台串行队列使用，全部 self-contained）。
private final class BatteryHealthLogStore {

    /// IO 失败此前全部被 `try?` 静默吞掉，历史丢失时无任何痕迹；改为记录到系统日志。
    private static let logger = Logger(subsystem: "com.zioon.macbattery", category: "io")

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
            // 用 String(decoding:as:) 而非 String(data:encoding:)：后者在块边界落在
            // 多字节字符中间时返回 nil，会 break 掉**整段**历史（与 1.1.5/1.1.9 反复出现的
            // "曲线空白"同源）。前者永不失败，非法字节替换为 U+FFFD，最多影响该行
            //（解析失败已由 parseCSVLine 返回 nil 处理）。
            var text = String(decoding: data, as: UTF8.self)
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
        // 因读取字节上限而提前结束（而非读完全部或凑够 limit）：历史文件过大，
        // 更早的数据被截断。此前静默发生，现在留下痕迹。
        if offset > 0 && result.count < limit {
            Self.logger.warning("历史文件过大，回填被截断: 剩余 \(offset, privacy: .public) 字节未读")
        }
        result = result.filter { $0.t != .distantPast }
        return result.sorted { $0.t < $1.t }
    }

    private func parseCSVLine(_ line: Substring) -> BatteryHealthSample? {
        let parts = line.split(separator: ",", omittingEmptySubsequences: false)
        // 兼容旧 6 列文件（含已废弃的 levelPercent 列）：多余的第 6 列直接忽略。
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