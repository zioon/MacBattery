# MacBattery

一款 macOS 置顶挂件（HUD），实时显示：

- **电量圆环**：外圈一圈进度弧 = 电量百分比，右下角有小百分比徽章
- **整机功率**（W）：第一行大数字
- **充电功率**（W）：第二行，充电中显示 ⚡ 图标与瓦数

窗口透明、置顶、鼠标穿透，不阻塞任何操作。默认 Xcode/SwiftUI 开发，无第三方依赖。

> 目标平台：macOS 12+，**Intel Mac 优先**（整机功率走 SMC 读取）。

---

## 用法

### 方式一：Swift / SPM（推荐，最快）

前置：安装 Xcode 或仅安装 Command Line Tools（自带 `swift`）。

```bash
cd d:/Project/MacBattery
swift run
```

编译完成后会自动启动浮窗，出现在**屏幕右上角**。

产物（可执行文件）为 `.build/debug/MacBattery`。正式使用时：

```bash
swift build -c release
```

### 方式二：打包成 .app（可选）

```bash
swift build -c release --arch arm64   # 按你的架构调整
# 将 .build/release/MacBattery 拷入你自建的 MacBattery.app/Contents/MacOS/
# 并补一个最小 Info.plist，即可双击运行、固定到 Dock。
```

### 退出

在运行它的终端里按 `Ctrl+C` 即可。

---

## 在线自动更新

- **启动时自动检查**：查询 GitHub Releases（`zioon/MacBattery`）最新版本，与当前版本比对。
- **发现新版本自动下载**：把 DMG 下载到「下载」文件夹（命名为 `MacBattery-<版本>.dmg`），并弹窗提示，可在访达中直接打开安装。
- **手动检查**：菜单栏图标 →「检查更新…」，或设置面板中的「检查更新」按钮。
- 版本号取自 `.app` 的 `Info.plist` 的 `CFBundleShortVersionString`（发版时由 CI 用 tag 覆盖）；
  `swift run` 直接运行裸二进制时回退到 `Updater.swift` 中的 `AppVersion.fallback`。
- 安装：打开 DMG，把 `MacBattery.app` 拖入「应用程序」覆盖旧版本即可（应用不会自我替换，避免签名与权限风险）。

---

## 数据来源与限制

| 数据 | 来源 | 权限 |
|---|---|---|
| 电量百分比 | IOKit Power Sources（`IOPSCopyPowerSourcesInfo`） | 无需 root |
| 充电功率 | AppleSmartBattery 电压 × 电流 | 无需 root |
| 整机功率 | AppleSMC（候选功耗键自动探测） | 视机型/系统；读不到时显示 `--` |

### 关于整机功率

macOS 没有读取"整机功耗"的官方公开 API。本实现通过 AppleSMC 探测一组候选键（`PSTR`、`PDTR`、`PCHC`、`PWRS`、`EDR0`）。

- **部分 Intel 机型 / 部分 macOS 版本**可以读到，此时显示真实瓦数；
- 读不到（显示 `--`）属正常现象，与该机固件未暴露功耗键有关，**并非程序错误**。

如需确定功耗，可临时用系统自带工具交叉验证（需管理员密码）：

```bash
sudo powermetrics --samplers smc -i 1000
```

若你希望通用性更强（覆盖更多 Intel 机型 / 自动回退到 IOReport 累加预估），可后续扩展 `Sources/MacBattery/SMC.swift` 与 `PowerMonitor.swift`。

## 真实整机功率（可选，需一次性 sudo）

Intel 机型上 macOS 不向普通权限暴露系统总功耗（`PSTR`），因此默认整机功率为估算值。
如需**真实整机功率**，可安装一个 root helper 守护（与 MacMonitor 同思路，一次性授权）：

```bash
cd 工程目录
sudo ./Scripts/install_helper.sh
```

- helper 以 root 常驻，每秒读一次 SMC `PSTR` 整机功耗，写入 `/tmp/macbattery_power.json`；
- 挂件每秒读取该文件，读到即显示真实值；
- 验证：`cat /tmp/macbattery_power.json`
- 卸载：`sudo launchctl bootout system /Library/LaunchDaemons/com.zioon.macbattery.helper.plist` 再删掉该 plist 与 `/Library/PrivilegedHelperTools/macbattery-helper`。

DMG 内已附带 `macbattery-helper` 二进制与 `install_helper.sh`，解压后在挂件工程内执行即可。

---

## 结构

```
Sources/MacBattery/
├── main.swift          # 入口
├── FloatingPanel.swift # 置顶透明穿透浮窗 + 位置
├── PowerHUDView.swift  # 圆环电量 + 两行功率 UI
├── PowerMonitor.swift  # 每秒刷新数据
├── Updater.swift       # 在线自动更新（GitHub Releases + DMG 下载）
├── Battery.swift       # 电量 + 充电功率（IOKit 官方 API）
└── SMC.swift           # AppleSMC 整机功率读取
```

## 调整项

- **位置**：改 `FloatingPanel.swift` 中 `placePanel` 的 `margin` 与起点坐标。
- **尺寸/配色**：改 `PowerHUDView.swift` 的 `frame`、圆环线宽、`ringColor` 阈值。
- **刷新间隔**：改 `PowerMonitor.swift` 中 `Timer` 的 `1.0` 秒。