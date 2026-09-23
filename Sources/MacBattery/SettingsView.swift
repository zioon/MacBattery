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
}
