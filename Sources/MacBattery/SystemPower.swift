import Foundation
import Darwin

/// 整机功率。优先级：
///  1) SMC 直读真实值（`PSTR` 等；无权限时可能读不到）
///  2) 已安装 root helper 守护时，读它实时写入的 `/tmp/macbattery_power.json` 真实功耗
///  3) 均不可用时，回退「CPU 功耗曲线 + 平台基础功耗」估算，保证始终有值显示
enum SystemPower {

    static func watts(tdp: Double, usage: Double? = nil) -> Double {
        let real = SMCReader.systemWatts()
        if real > 0 { return real }

        let helper = readHelperPower()
        if helper > 0 { return helper }

        let u = max(0, min(1, usage ?? cpuUsage()))
        let cpuPower = tdp * (0.05 + 0.95 * u)
        let platformPower = 7 + 3 * u
        return cpuPower + platformPower
    }

    /// 当前内存使用率（0...1）。用 host_statistics64 读取活动/有线/压缩页数，除以物理内存总量。
    static func memoryUsage() -> Double {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        guard pageSize > 0 else { return 0 }

        let used = Double(stats.active_count + stats.wire_count + stats.compressor_page_count)
            * Double(pageSize)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return 0 }
        return min(1, max(0, used / total))
    }

    /// 读取 root helper 写入的真实整机功率。helper 未安装时返回 0。
    private static func readHelperPower() -> Double {
        let url = URL(fileURLWithPath: "/tmp/macbattery_power.json")
        guard let data = try? Data(contentsOf: url) else { return 0 }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj["systemPower"] as? Double,
              value > 0 else { return 0 }
        return value
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