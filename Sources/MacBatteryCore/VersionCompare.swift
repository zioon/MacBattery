import Foundation

/// 语义化版本比较：仅比较数字段，`v` 前缀与非数字后缀（如 `-beta`）忽略。
///
/// 用于应用内自动更新的版本比对 —— 必须按数字段比较，
/// 字符串比较会把 `1.10` 判成小于 `1.9`。
public enum VersionCompare {

    /// remote 是否比 local 更新。
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = components(remote)
        let b = components(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 拆成数字段：`v`/`V` 前缀剥掉，非数字字符作为分隔符（`-beta` 等后缀随之丢弃）。
    private static func components(_ s: String) -> [Int] {
        let trimmed = (s.hasPrefix("v") || s.hasPrefix("V")) ? String(s.dropFirst()) : s
        return trimmed.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
    }
}
