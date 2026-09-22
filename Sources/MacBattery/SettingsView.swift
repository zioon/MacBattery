import SwiftUI
import AppKit
import MacBatteryCore

/// 设置面板：语言、大小、位置、鼠标穿透、整机功率估算上限（TDP）、在线更新。
///
/// 文案一律经 `L("key")` 取（返回 `String`，`Text(String)` 按字面渲染）。
/// ⚠️ 不要改回 `Text("中文")`：字面量会被当成 `LocalizedStringKey` 走 `Bundle.main`，
/// 绕过应用内的语言选择，切语言后这一处不会跟着变。
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var updater: UpdateChecker

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
    }
}
