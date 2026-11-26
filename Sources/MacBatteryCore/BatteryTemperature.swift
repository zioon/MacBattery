import Foundation
import Darwin

/// 电池温度的量纲与换算（注册表 `AppleSmartBattery.Temperature` 的唯一定义处）。
///
/// 同一个键在不同硬件上量纲不同，且两者的数值在常见温度区间**无法区分**
///（3105 既可能是 Intel 的 310.5 K = 37.35℃，也可能是 Apple silicon 的 31.05℃），
/// 因此只能按硬件架构判定：
/// - Intel：0.1 K（Smart Battery 原始量纲）→ ℃ = raw/10 - 273.15
/// - Apple silicon：0.01 ℃ → ℃ = raw/100
///
/// 判定用运行时的 `hw.optional.arm64`，**不用** `#if arch(x86_64)`：
/// 通用二进制在 Apple silicon 上被 Rosetta 翻译运行时，编译期分支会误判成 Intel，
/// 而传感器量纲仍由硬件决定（0.01℃）。
///
/// 换算与修正都显式接收 `Scale`，两条路径都能在任意架构的机器上单测
///（默认量纲才依赖运行时硬件）。
public enum BatteryTemperature {

    /// 注册表 `Temperature` 的量纲。
    public enum Scale {
        /// 0.01℃（Apple silicon）。
        case centiCelsius
        /// 0.1 K（Intel，Smart Battery 原始量纲）。
        case deciKelvin
    }

    /// 是否 Apple silicon 硬件（含 Rosetta 翻译运行的本进程）。
    public static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else {
            // Intel 机型没有这个键（Apple silicon 一定有）。
            return false
        }
        return value == 1
    }()

    /// 本机应使用的量纲。
    public static var scale: Scale { isAppleSilicon ? .centiCelsius : .deciKelvin }

    /// 温度的合理区间（℃）：超出即不可能是真实的电池读数。
    static let plausibleCelsius = -20.0...80.0
    /// 温度的合理区间（0.1℃ 定点），与 `plausibleCelsius` 等价。
    static let plausibleDeci = -200...800

    /// 原始读数 → ℃。超出合理区间返回 nil（未知），不让异常尖峰进趋势图。
    public static func celsius(fromRaw raw: Int, scale: Scale) -> Double? {
        let celsius: Double
        switch scale {
        case .centiCelsius: celsius = Double(raw) / 100.0
        case .deciKelvin: celsius = Double(raw) / 10.0 - 273.15
        }
        return plausibleCelsius.contains(celsius) ? celsius : nil
    }

    /// 原始读数 → ℃（按本机量纲）。
    public static func celsius(fromRaw raw: Int) -> Double? {
        celsius(fromRaw: raw, scale: scale)
    }

    /// 修正 v1.5.0 早期落盘的温度（**读取时**修正，不重写文件）。
    ///
    /// 当时的换算把 `Temperature` 一律当 0.1℃ 直接除以 10，落盘值恰好等于**注册表原始值**
    ///（Intel 的 3105 与 Apple silicon 的 3105 都被写成 3105）。现在按量纲重新换算：
    /// - Intel：3105 → 37.35℃ → 374（0.1℃ 定点）
    /// - Apple silicon：3105 → 31.05℃ → 311
    ///
    /// 已是合法新值的行原样返回；换算后仍超出合理区间 → nil（未知），
    /// 不让 310℃ 这类读数继续污染趋势图与统计。
    ///
    /// 取舍：Intel 上旧原始值恒 >2000，与新值（≤800）没有重叠带；
    /// 仅 Apple silicon 上落在 0…800 的旧值（真实温度 0…8℃）与新版正确值无法区分，
    /// 按新版解读 —— 宁可少数低温旧点偏 10 倍，也不冒把正常新数据改错的风险。
    public static func repairedDeci(_ stored: Int, scale: Scale) -> Int? {
        if plausibleDeci.contains(stored) { return stored }
        guard let celsius = celsius(fromRaw: stored, scale: scale) else { return nil }
        // 合理区间在 ℃ 上已限定为 -20…80，×10 取整后必然落在 -200…800 内。
        return Int((celsius * 10).rounded())
    }

    /// 修正早期落盘的温度（按本机量纲）。
    public static func repairedDeci(_ stored: Int) -> Int? {
        repairedDeci(stored, scale: scale)
    }
}
