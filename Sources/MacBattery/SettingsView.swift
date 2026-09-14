import SwiftUI
import AppKit

/// 设置面板：大小、位置、鼠标穿透、整机功率估算上限（TDP）、在线更新。
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var updater: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MacBattery 设置").font(.headline)

            Picker("大小", selection: $store.sizeRaw) {
                ForEach(SizePreset.allCases, id: \.rawValue) { p in
                    Text(p.label).tag(p.rawValue)
                }
            }

            Picker("位置", selection: $store.cornerRaw) {
                ForEach(Corner.allCases, id: \.rawValue) { c in
                    Text(c.label).tag(c.rawValue)
                }
            }
            if store.hasCustom {
                Text("已在自定义位置（拖动挂件/重选四角可更改）")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Toggle("鼠标穿透（开启后不可拖动）", isOn: $store.passthrough)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("整机功率估算上限 (TDP)")
                    Spacer()
                    Text("\(Int(store.tdpWatts)) W")
                        .foregroundColor(.secondary)
                }
                Slider(value: $store.tdpWatts, in: 20...180, step: 5)
                Text("整机功率在 Intel 机型上 macOS 不提供实测值，这里按机型最大功耗估算。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("把它调到接近你机型的额定功耗（如轻薄本 28W、标压 U 45W、H 系 60W+），整机功率会更贴近真实。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("当前版本 \(AppVersion.current)")
                    Spacer()
                    Button("检查更新") { updater.checkForUpdates(interactive: true) }
                        .disabled(updater.state.isBusy)
                }
                Text(updater.state.summary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("启动时会自动检查，发现新版本将自动下载 DMG 到「下载」文件夹。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("完成") {
                    store.commit()
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)

        // 任何设置改变即持久化并应用
        .onChange(of: store.sizeRaw) { _ in store.commit() }
        .onChange(of: store.cornerRaw) { _ in store.commit() }
        .onChange(of: store.passthrough) { _ in store.commit() }
        .onChange(of: store.tdpWatts) { _ in store.commit() }
    }
}