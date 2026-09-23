import Foundation

/// 充电上限：**参数与决策规则**（纯逻辑层，无任何系统依赖，可独立单测）。
///
/// 为什么这里只有「决策」没有「执行」——macOS 没有公开 API 能停止充电，唯一可行的手段是写
/// AppleSMC 的充电抑制键（`CH0B` / `CH0C`：`0x00` = 允许、`0x02` = 抑制），需要 root 权限，
/// 而且**并非所有机型都提供这些键**。因此本功能被拆成三层：
///
/// 1. 本类型 —— 给定「电量 / 上限 / 电源状态 / 当前是否已抑制」，算出期望动作（含迟滞）；
/// 2. `MacBatteryHelper`（root 守护）—— 唯一的执行者，把动作翻译成 SMC 写；
/// 3. `ChargeLimiter`（应用层）—— 驱动本策略、下发动作、把实际状态回报给界面。
///
/// 这样分层的好处：阈值、迟滞、未接电、上限=100 等全部边界都能在 CI 的 `swift test` 里被断言。
/// 本机没有 Swift 工具链，CI 是唯一的编译与验证通道 —— 决策必须是纯的，否则「触发了没有」
/// 只能靠肉眼盯着一台真机看，等于没有验证。
public enum ChargeLimitPolicy {

    /// 上限可选范围下界（%）。低于此值对锂电池寿命意义不大，反而更容易误触发。
    public static let minimumPercent = 50

    /// 上限可选范围上界（%）。
    ///
    /// **100 表示「不限制」**：它与关闭功能等价，因此不会下发任何指令。
    /// 这样处理可以避免与系统自带的「优化电池充电 / 电池健康管理」在一个不可能达到的
    /// 阈值上互相拉扯（系统本来就会在 100% 前自行收尾）。
    public static let maximumPercent = 100

    /// 滑块步进（%）。
    public static let stepPercent = 5

    /// 默认上限（%）：80% 是「长期插电使用」场景下公认的折中点。
    public static let defaultPercent = 80

    /// 迟滞带宽（%）：达到上限并暂停充电后，需回落到 `上限 − 该值` 才恢复充电。
    ///
    /// 没有它就会在阈值附近反复抖动：涓流让电量在 80% 上下反复穿越阈值，充电被反复启停，
    /// 既伤电池（充电器/充电电路频繁启停）也让用户在界面上看到状态来回跳。
    /// 取 5%，与系统「优化电池充电」的观感一致。
    public static let hysteresisPercent = 5

    /// 期望动作。
    public enum Action: Equatable {
        /// 下发「禁止充电」。
        case inhibitCharging
        /// 下发「允许充电」。
        case allowCharging
        /// 什么也不下发：本功能不该介入当前状况。
        case noChange
    }

    /// 把任意整数上限夹取到合法范围并对齐步进。
    ///
    /// 这是设置项的**读回护栏**：手改 plist、跨版本残留、越界值都不该让界面出现 37% 这类数值，
    /// 也不该让滑块落到 50...100 之外。
    public static func clamp(_ percent: Int) -> Int {
        let bounded = min(max(percent, minimumPercent), maximumPercent)
        let offset = bounded - minimumPercent
        let stepped = minimumPercent
            + Int((Double(offset) / Double(stepPercent)).rounded()) * stepPercent
        return min(max(stepped, minimumPercent), maximumPercent)
    }

    /// 决策入口：由当前状况推出手柄该处于哪个状态。
    ///
    /// 触发条件（按判定顺序，先命中先返回）：
    /// 1. 功能未启用，或上限为 100（= 不限制）→ `.noChange`，完全不干预；
    /// 2. 未接外电（电池供电）→ `.noChange`：断电时抑制充电没有意义，
    ///    也避免拔掉电源后还残留一条「禁止充电」的指令；
    /// 3. 电量已达上限 → `.inhibitCharging`；
    /// 4. 已在抑制中、且电量仍高于「上限 − 迟滞带」→ 维持 `.inhibitCharging`（迟滞，防抖动）；
    /// 5. 其余（电量已回落到迟滞带以下）→ `.allowCharging`，恢复充电。
    ///
    /// - Parameters:
    ///   - level: 当前电量（0...100）。
    ///   - limit: 用户设定的上限（%）。越界值请先过 `clamp(_:)`。
    ///   - enabled: 功能总开关。
    ///   - onExternalPower: 是否接着外接电源。
    ///     ⚠️ **不要传 `isCharging`**：已插电但充电被暂停时 `isCharging` 为 false，
    ///     用它判定会在「刚刚到达上限」的瞬间误判成「没插电」从而撤回抑制，
    ///     下一拍又重新抑制 —— 形成每秒一次的启停振荡。
    ///   - currentlyInhibited: 当前硬件上是否**确实**处于抑制状态（来自 helper 回执，
    ///     不是「我们下发过抑制」）。
    public static func action(level: Int,
                              limit: Int,
                              enabled: Bool,
                              onExternalPower: Bool,
                              currentlyInhibited: Bool) -> Action {
        guard enabled, limit < maximumPercent else { return .noChange }
        guard onExternalPower else { return .noChange }
        if level >= limit { return .inhibitCharging }
        // 迟滞带：只在「明显回落」后才恢复充电，避免在阈值上下反复启停。
        if currentlyInhibited && level > limit - hysteresisPercent { return .inhibitCharging }
        return .allowCharging
    }

    /// 电量是否已达（或超过）上限。界面用它决定要不要显示「已限充」与上限刻度。
    public static func isAtLimit(level: Int, limit: Int, enabled: Bool) -> Bool {
        enabled && limit < maximumPercent && level >= limit
    }
}
