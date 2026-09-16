import Foundation
import Darwin
import MacBatteryCore

/// 整机功率。优先级：
///  1) SMC 直读真实值（`PSTR` 等；无权限时可能读不到）
///  2) 已安装 root helper 守护时，读它实时写入的 `/tmp/macbattery_power.json` 真实功耗
///  3) 均不可用时，回退「CPU 功耗曲线 + 平台基础功耗」估算，保证始终有值显示
enum SystemPower {

    /// 整机功率读数及其可信度。`isEstimate == true` 表示这是经验公式估算值，不是实测。
    struct Reading {
        /// 整机功率（瓦特）。
        var watts: Double
        /// 是否为经验公式估算值（true = 估算，UI 以 `~` 前缀区分；false = 实测）。
        var isEstimate: Bool
    }

    /// 保护静态状态 `lastCpuTicks` 的锁。
    /// 用 `NSRecursiveLock`（而非 `NSLock`）以容忍同类型内的嵌套调用；目标 macOS 12，
    /// 不使用 macOS 13+ 的 `OSAllocatedUnfairLock`。
    private static let lock = NSRecursiveLock()

    /// 返回整机功率读数（瓦特 + 是否估算）。
    /// - 分支 1（SMC 直读）与分支 2（root helper 写入的真实值）均为**实测**；
    /// - 分支 3 为**估算**（`isEstimate = true`）。
    static func watts(tdp: Double, usage: Double? = nil) -> Reading {
        let real = SMCReader.systemWatts()
        if real > 0 { return Reading(watts: real, isEstimate: false) }

        let helper = readHelperPower()
        if helper > 0 { return Reading(watts: helper, isEstimate: false) }

        let u = max(0, min(1, usage ?? cpuUsage()))
        // 估算公式抽到 MacBatteryCore/PowerEstimate（纯函数，可独立单测）。
        return Reading(watts: PowerEstimate.watts(tdp: tdp, usage: u), isEstimate: true)
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
        // 保护静态状态 `lastCpuTicks` 的「读—改—写」：本函数会被后台采样线程与
        // 主线程（首拍 / 电源事件 / 设置变更刷新）并发调用，需要对增量基线做串行化。
        // 函数体内不调用其他被锁类型、也无子进程，整体持锁安全。
        // 注意：`watts()` 不持锁，故此处不会与 SMCReader.lock 形成嵌套。
        lock.lock()
        defer { lock.unlock() }

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