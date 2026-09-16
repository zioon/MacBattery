import Foundation

/// 把磁盘历史与内存新采样按时间升序合并、去重，并裁剪到容量上限。
///
/// 功率日志与电池健康日志共用，避免"回填覆盖内存新采样"只在一处修好、另一处漏修
/// （v1.1.9 在健康日志修过，功率日志漏修）。
///
/// 回填是异步的：它抵达时内存里可能已经有新采样（新点先到），也可能还没有（回填先到）。
/// 两种顺序下本函数的输出都同时包含两侧数据，因此调用方无需关心时序。
///
/// - Parameters:
///   - history: 从磁盘读回的历史样本（升序或无序均可，函数内部会排序）。
///   - new: 内存中已有的新采样。
///   - timestamp: 取样本时间戳的闭包（两个日志的样本类型都有 `t: Date`）。
///   - capacity: 内存容量上限，超出时从**最旧**的一端裁剪。
/// - Returns: 升序、按时间戳去重（同时间戳时 new 覆盖 history）且不超过容量的数组。
public func mergedByTimestamp<T>(history: [T],
                                 new: [T],
                                 timestamp: (T) -> Date,
                                 capacity: Int) -> [T] {
    // Swift 的 sorted(by:) 不保证稳定排序，「同时间戳 new 覆盖 history」若只靠追加顺序
    // 就是未定义行为。这里给两侧加上显式次序（history=0、new=1），使该承诺真正成立。
    let tagged = history.map { (item: $0, order: 0) } + new.map { (item: $0, order: 1) }
    let pooled = tagged.sorted { a, b in
        let ta = timestamp(a.item), tb = timestamp(b.item)
        if ta != tb { return ta < tb }
        return a.order < b.order
    }
    var deduped: [T] = []
    for s in pooled {
        if let last = deduped.last, timestamp(last) == timestamp(s.item) {
            deduped[deduped.count - 1] = s.item
        } else {
            deduped.append(s.item)
        }
    }
    if deduped.count > capacity {
        deduped.removeFirst(deduped.count - capacity)
    }
    return deduped
}
