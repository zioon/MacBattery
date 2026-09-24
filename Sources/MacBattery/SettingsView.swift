import SwiftUI
import AppKit
import MacBatteryCore

/// 设置面板：语言、大小、位置、鼠标穿透、整机功率估算上限（TDP）、充电上限、在线更新。
///
/// 文案一律经 `L("key")` 取（返回 `String`，`Text(String)` 按字面渲染）。
/// ⚠️ 不要改回 `Text("中文")`：字面量会被当成 `LocalizedStringKey` 走 `Bundle.main`，
/// 绕过应用内的语言选择，切语言后这一处不会跟着变。
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var updater: UpdateChecker
    /// 充电上限的**实际生效状态**（helper 可用性、是否已限充…）。
    /// 与 `store.chargeLimit*` 的分工：store 是「用户想怎样」，limiter 是「本机实际怎样」。
    @ObservedObject var limiter: ChargeLimiter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("window.settings")).font(.headline)

            // 语言入口放在最上方：与 macOS「每应用语言」的习惯一致。
            Picker(L("settings.language"), selection: $store.language) {
                ForEach(AppLanguage.allCases, id: \.rawValue) { lang in
                    Text(lang.menuLabel).tag(lang)
                }
            }

            Toggle(L("settings.widget_toggle"), isOn: $store.widgetVisible)

            // 挂件隐藏后，下面三项（大小 / 位置 / 穿透）都没有可作用的对象 —— 置灰而不是整段移除：
            // 控件不跳动、文字不重排，用户也能看出「这几项属于挂件」。
            Group {
                Picker(L("common.size"), selection: $store.sizeRaw) {
                    ForEach(SizePreset.allCases, id: \.rawValue) { preset in
                        Text(L(preset.localizationKey)).tag(preset.rawValue)
                    }
                }

                Picker(L("common.position"), selection: $store.cornerRaw) {
                    ForEach(Corner.allCases, id: \.rawValue) { corner in
                        Text(L(corner.localizationKey)).tag(corner.rawValue)
                    }
                }
                if store.hasCustom {
                    Text(L("settings.custom_position_hint"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(L("settings.passthrough_toggle"), isOn: $store.passthrough)
            }
            .disabled(!store.widgetVisible)

            Text(L("settings.widget_hint"))
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("settings.tdp.title"))
                    Spacer()
                    Text(L("settings.tdp.value", Int(store.tdpWatts)))
                        .foregroundColor(.secondary)
                }
                Slider(value: $store.tdpWatts, in: 20...180, step: 5)
                // 说明文字允许换行而不是截断：英文比中文长，固定 340pt 宽下必须靠换行容纳。
                Text(L("settings.tdp.hint.estimate"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("settings.tdp.hint.calibrate"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("settings.tdp.hint.tilde"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            chargeLimitSection

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("settings.version.current", AppVersion.current))
                    Spacer()
                    Button(L("settings.check_update")) { updater.checkForUpdates(interactive: true) }
                        .disabled(updater.state.isBusy)
                }
                Text(updater.state.summary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("settings.update.auto_hint"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L("settings.done")) {
                    store.commit()
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)

        // 任何设置改变即持久化并应用
        .onChange(of: store.language) { _ in store.commit() }
        .onChange(of: store.sizeRaw) { _ in store.commit() }
        .onChange(of: store.cornerRaw) { _ in store.commit() }
        .onChange(of: store.widgetVisible) { _ in store.commit() }
        .onChange(of: store.passthrough) { _ in store.commit() }
        .onChange(of: store.tdpWatts) { _ in store.commit() }
        .onChange(of: store.chargeLimitEnabled) { _ in store.commit() }
        .onChange(of: store.chargeLimitPercent) { _ in store.commit() }
    }

    // MARK: - 充电上限

    /// 充电上限设置区：开关 + 上限滑块 + 当前上限 + 实际生效状态 + 前置条件说明。
    private var chargeLimitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L("settings.charge_limit.toggle"), isOn: $store.chargeLimitEnabled)

            HStack {
                Text(L("settings.charge_limit.title"))
                Spacer()
                // 上限值就在这里显示（可调 + 当前值同一处，避免"设置值 / 生效值"两行互相打架）：
                // 100% 换成一句人话，否则用户会以为"设成 100 就会在 100% 断充"。
                Text(isUnlimited
                     ? L("settings.charge_limit.value.unlimited")
                     : L("settings.charge_limit.value", store.chargeLimitPercent))
                    .foregroundColor(.secondary)
            }
            Slider(value: chargeLimitBinding,
                   in: Double(ChargeLimitPolicy.minimumPercent)...Double(ChargeLimitPolicy.maximumPercent),
                   step: Double(ChargeLimitPolicy.stepPercent))
                .disabled(!store.chargeLimitEnabled)

            Text(chargeLimitStatusText)
                .font(.caption2)
                .foregroundColor(chargeLimitStatusColor)
                .fixedSize(horizontal: false, vertical: true)

            // helper 的当前状态：把「有没有人在执行」变成可核对的事实（回执几秒前），
            // 顺带回答「为什么没生效」。功能关着时也显示 —— 它是这一区块的前置依赖。
            Text(helperStatusText)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // SMC 探测结果：只在功能不可用时出现，是「为什么本机不支持」的唯一答案来源。
            // 内容是键名 + 十六进制取值（语言无关的排查数据），因此不经过 L()。
            if let probe = limiter.probeSummary {
                Text(L("settings.charge_limit.probe", probe))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Text(L("settings.charge_limit.hint.helper"))
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("settings.charge_limit.hint.system"))
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 上限为 100% 等价于「不限制」，界面上要说清楚，别让用户以为它在 100% 会断充。
    private var isUnlimited: Bool {
        store.chargeLimitPercent >= ChargeLimitPolicy.maximumPercent
    }

    /// 滑块的 Double ↔ Int 桥接：`Slider` 只接受浮点，而设置里存的是整数百分比。
    /// 取整交给 `round()`，避免拖动过程中出现 79.999… 被截断成 79 的抖动。
    private var chargeLimitBinding: Binding<Double> {
        Binding(get: { Double(store.chargeLimitPercent) },
                set: { store.chargeLimitPercent = Int($0.rounded()) })
    }

    /// 状态提示文案。
    ///
    /// 刻意把「选键」和「调用 `L()`」写在同一个分支里，而不是先算出一个键变量再统一取文案：
    /// · 带 `%d` 的文案必须先于取文案确定参数个数，拆成两个 switch 就可能不同步 ——
    ///   而 `String(format:)` 少参会读出垃圾值且**不报错**；
    /// · 键作为字面量出现在 `L("...")` 里，CI 的 `check_localization_keys.py`
    ///   才能校验「引用的键确实存在」（它只认字面量键）。写成变量的键是校验盲区，
    ///   拼错了只会在界面上原样显示键名。
    private var chargeLimitStatusText: String {
        switch limiter.phase {
        case .off:
            return L("settings.charge_limit.status.off")
        case .unlimited:
            return L("settings.charge_limit.status.unlimited")
        case .onBattery(let limit):
            return L("settings.charge_limit.status.on_battery", limit)
        case .charging(let limit):
            return L("settings.charge_limit.status.charging", limit)
        case .holding(let limit):
            return L("settings.charge_limit.status.holding", limit)
        case .unavailable(let reason):
            switch reason {
            case .notInstalled:
                return L("settings.charge_limit.status.not_installed")
            case .notRunning:
                return L("settings.charge_limit.status.not_running")
            case .outdatedHelper:
                return L("settings.charge_limit.status.outdated_helper")
            case .unsupportedHardware:
                return L("settings.charge_limit.status.unsupported")
            case .unrecognizedValues:
                return L("settings.charge_limit.status.unrecognized")
            case .smcUnreadable:
                return L("settings.charge_limit.status.smc_unreadable")
            }
        }
    }

    /// 状态配色：已限充用绿（"已经按你说的停住了"），执行不了用橙（需要用户处理），
    /// 其余为次要色。
    private var chargeLimitStatusColor: Color {
        switch limiter.phase {
        case .holding:
            return Color(red: 0.16, green: 0.72, blue: 0.42)
        case .unavailable:
            return .orange
        case .off, .unlimited, .onBattery, .charging:
            return .secondary
        }
    }

    // MARK: - helper 状态

    /// helper 的当前状态（一行）。
    ///
    /// 与上面那条「状态提示」的分工：**这条说的是 helper 本身**（在不在跑、能不能读 SMC），
    /// 上面那条说的是**功能是否生效**。两者分开，用户才能自己判断"到底是没人干活，
    /// 还是干不了这个活" —— 这也是「装了 helper 却只看到一句不支持」那次反馈的核心。
    private var helperStatusText: String {
        switch limiter.availability {
        case .ready:
            return runningHelperText
        case .unavailable(let reason):
            switch reason {
            case .notInstalled:
                return L("settings.charge_limit.helper.not_installed")
            case .notRunning:
                return L("settings.charge_limit.helper.not_running")
            case .outdatedHelper:
                return L("settings.charge_limit.helper.outdated")
            case .smcUnreadable, .unsupportedHardware, .unrecognizedValues:
                // helper 在跑，只是读不到 SMC / 找不到可用键 —— 状态行照实报"运行中"，
                // SMC 那一格由 `smcReadable` 决定，不在这里另写一套判断。
                return runningHelperText
            }
        }
    }

    /// 「运行中」那一行的拼装：三个片段（运行中 / 回执年龄 / SMC 可读性）组合起来，
    /// 比为一个可变组合写四份完整文案更容易保持一致。
    ///
    /// 两个分支刻意写成 if/else 而不是 `L(cond ? "a" : "b")`：后者的参数不是字面量，
    /// CI 的键存在性检查（只认 `L("...")`）看不见它 —— 拼错只会在界面上原样显示键名。
    private var runningHelperText: String {
        let smc: String
        if limiter.smcReadable {
            smc = L("settings.charge_limit.helper.smc_ok")
        } else {
            smc = L("settings.charge_limit.helper.smc_failed")
        }
        return L("settings.charge_limit.helper.running", helperAgeText, smc)
    }

    /// 回执年龄的人类可读形式。复用既有的复数时长文案，避免为只出现一次的场景再加一串键。
    private var helperAgeText: String {
        guard let age = limiter.lastStatusAge else { return L("common.placeholder") }
        if age < 60 { return LP("duration.seconds", count: Int(age.rounded())) }
        return LP("duration.minutes", count: Int((age / 60).rounded()))
    }
}
