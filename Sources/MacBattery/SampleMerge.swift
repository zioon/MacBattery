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
/// - Returns: 升序、按时间戳去重（后出现的覆盖先出现的）且不超过容量的数组。
func mergedByTimestamp<T>(history: [T],
                          new: [T],
                          timestamp: (T) -> Date,
                          capacity: Int) -> [T] {
    let pooled = (history + new).sorted { timestamp($0) < timestamp($1) }
    var deduped: [T] = []
    for s in pooled {
        if let last = deduped.last, timestamp(last) == timestamp(s) {
            deduped[deduped.count - 1] = s
        } else {
            deduped.append(s)
        }
    }
    if deduped.count > capacity {
        deduped.removeFirst(deduped.count - capacity)
    }
    return deduped
}
