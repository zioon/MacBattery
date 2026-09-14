import Foundation
import Darwin

/// 整机功率：优先尝试 SMC 读取真实值；读不到（无权限 / 该机型无此键）时，
/// 回退为「CPU 使用率 × 用户配置的最大功耗」的估算值，保证始终有数值可显示。
enum SystemPower {

    /// 整机功率（瓦特）。
    static func watts(tdp: Double) -> Double {
        let real = SMCReader.systemWatts()
        if real > 0 { return real }
        let usage = cpuUsage()
        let idleBase = 6.0        // 屏幕 / 基本外设等基础功耗的粗略估计
        let estimate = idleBase + usage * tdp
        return max(0.5, estimate)
    }

    /// 当前 CPU 平均使用率（0...1）。用两次调用之间的 tick 增量计算，
    /// 由调用方（每秒刷新）自然形成稳定间隔，避免在采样时 sleep 阻塞。
    private static var lastCpuTicks: CpuTicks?

    static func cpuUsage() -> Double {
        guard let now = loadCpuTicks() else { return 0 }
        guard let previous = lastCpuTicks else {
            lastCpuTicks = now
            return 0
        }
        defer { lastCpuTicks = now }

        let totalDelta = (now.user + now.system + now.idle + now.nice)
            - (previous.user + previous.system + previous.idle + previous.nice)
        guard totalDelta > 0 else { return 0 }
        let idleDelta = now.idle - previous.idle
        return min(1, max(0, 1 - idleDelta / totalDelta))
    }

    /// 结构化的 CPU 各状态累计 tick。
    private struct CpuTicks {
        let user: Double
        let system: Double
        let idle: Double
        let nice: Double
    }

    private static func loadCpuTicks() -> CpuTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return CpuTicks(user: Double(info.cpu_ticks.0),
                        system: Double(info.cpu_ticks.1),
                        idle: Double(info.cpu_ticks.2),
                        nice: Double(info.cpu_ticks.3))
    }
}