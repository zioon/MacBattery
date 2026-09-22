# MacBattery

<p align="center">
  <img src="Resources/screenshot.png" width="180" alt="MacBattery 运行截图" />
</p>

<div align="center">

[![GitHub release (latest by date)](https://img.shields.io/github/v/release/zioon/MacBattery?style=flat-square&label=release)](https://github.com/zioon/MacBattery/releases)
[![GitHub Actions status](https://img.shields.io/github/actions/workflow/status/zioon/MacBattery/build-dmg.yml?style=flat-square&label=build)](https://github.com/zioon/MacBattery/actions)
[![Platform macOS 12+](https://img.shields.io/badge/platform-macOS%2012%2B-black?style=flat-square&logo=apple&logoColor=white)]()
[![Swift](https://img.shields.io/badge/Swift-5.7-orange?style=flat-square&logo=swift&logoColor=white)]()

</div>

一款 macOS 置顶挂件（HUD），实时显示电脑电量、充电功率与整机功率，并附带历史功率图表、电池健康记录与应用内更新。

- **电量圆环**：外圈一圈进度弧 = 电量百分比，环色随电量平滑过渡（红 → 橙 → 黄绿 → 绿 → 青绿），右下角有小百分比徽章
- **充电环**：充电时进度弧外侧出现一圈矩形充电环，带呼吸光晕 / 扫过高光 / 闪电脉冲等特效，颜色随电量与充电状态变化
- **整机功率**（W）：第一行大数字
- **充电功率**（W）：第二行，充电中显示 ⚡ 图标与瓦数，下方附电压 · 电流小字（如 `12.3V · 1.2A`）
- **CPU / RAM**：内圈上下半环实时显示 CPU 与内存占用
- **历史图表**：记录并可视化电量、充电电压 / 电流、整机功率与 CPU / 内存占用
- **电池健康**：记录并可视化循环次数、当前 / 设计容量与健康度曲线

窗口透明、置顶、鼠标穿透，不阻塞任何操作。纯 Xcode/SwiftUI 开发，仅依赖系统自带的 SMC/IOKit 接口，无第三方依赖。

> 目标平台：macOS 12+，**Intel Mac 优先**（整机功率走 SMC 读取）。

---

## 用法

### 方式一：Swift / SPM（推荐，最快）

前置：安装 Xcode 或仅安装 Command Line Tools（自带 `swift`）。

```bash
cd <MacBattery 工程目录>
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

### 交互

- Ctrl + C 在运行它的终端里退出；
- 菜单栏图标提供全部窗口入口与「检查更新…」（⌘G 历史图表、⌘H 电池健康、⌘, 设置）；
- 历史图表 / 电池健康窗口支持滚轮缩放时间窗、拖拽平移、鼠标悬停看数值。

---

## 语言（国际化）

- **支持语言**：简体中文（默认语言，同时是回退目标）、English。在设置窗口顶部的「语言」里切换，
  **即时生效、无需重启**；选择持久化在 `MacBattery.Settings.language`，不写入 `AppleLanguages`、不改系统偏好。
- **首次启动**：按系统首选语言自动匹配（`en-*` → English，`zh-CN` / `zh-Hans-*` → 简体中文）；
  都不匹配时使用默认语言简体中文（繁体 `zh-Hant-*` 属第二批候选，当前回退到简体）。
- **回退机制**：某条文案在所选语言缺失时回退到默认语言；两处都缺时显示键名并写入日志 —— 不崩溃、不留空白。
- **数字与日期按区域格式化**：小数分隔符、12/24 小时制、日期顺序都随语言（英文区域用 12 小时制）。
- **新增文案**：代码里写 `L("your.key")`，再到 `Sources/MacBatteryCore/Resources/<lang>.lproj/Localizable.strings` 补条目；
  复数用 `<key>.one` / `<key>.other` 后缀。漏翻译不会让界面出问题，但会让 CI 的键名一致性测试失败。
- **改文案时的铁律**：SwiftUI 里必须写 `Text(L("key"))`，**不要**写 `Text("中文")` ——
  字面量会被当成 `LocalizedStringKey` 走 `Bundle.main`，绕过应用内的语言选择，表现为「切了语言这一处不变」。
  CI 的 `Scripts/check_hardcoded_strings.py` 会拦下这类残留；`logger.error(...)` 等日志调用里的中文属**刻意保留**
  （日志面向排查，本地化后同一条故障在不同语言下文本不同、无法检索），脚本按调用形态豁免。
- **CI 还会跑 `Scripts/check_localization_keys.py`**：校验各语言键名一致（漏翻译即失败）、格式占位符数量一致、
  以及代码里引用的键确实存在（`L("拼错的键")` 在运行时会在界面上显示键名，靠这个提前拦住）。

---

## 在线自动更新

- **启动时自动检查**：查询 GitHub Releases（`zioon/MacBattery`）最新版本，与当前版本比对。
- **发现新版本自动下载**：把 DMG 下载到「下载」文件夹（命名为 `MacBattery-<版本>.dmg`），并弹窗提示，可在访达中直接打开安装。
- **手动检查**：菜单栏图标 →「检查更新…」，或设置面板中的「检查更新」按钮。
- 版本号取自 `.app` 的 `Info.plist` 的 `CFBundleShortVersionString`（发版时由 CI 用 tag 覆盖）；
  `swift run` 直接运行裸二进制时回退到 `Updater.swift` 中的 `AppVersion.fallback`。
- 安装：打开 DMG，把 `MacBattery.app` 拖入「应用程序」覆盖旧版本即可（应用不会自我替换，避免签名与权限风险）。
  DMG 根目录已放好一个指向 `/Applications` 的「应用程序」快捷方式，无需再手动开一个访达窗口。

> **首次打开提示**：当前发布的 App 只做 ad-hoc 签名（未使用 Apple 开发者证书）。首次双击运行可能被 Gatekeeper 拦截并提示"无法验证开发者"。此时请**右键点按 App 图标 →「打开」**，或前往「系统设置 → 隐私与安全性」点「仍要打开」即可放行。

---

## 数据来源与限制

| 数据 | 来源 | 权限 |
|---|---|---|
| 电量百分比 | IOKit Power Sources（`IOPSCopyPowerSourcesInfo`） | 无需 root |
| 充电功率 | AppleSmartBattery 电压 × 电流（充电时取电流绝对值） | 无需 root |
| 电压 · 电流小字 | AppleSmartBattery | 无需 root |
| CPU / 内存 | POSIX / 系统接口 | 无需 root |
| 整机功率 | AppleSMC 直读 / root helper / 估算回退 | 视机型/系统；读不到时回退为估算值，UI 上以 `~` 前缀标注 |

### 关于整机功率

macOS 没有读取"整机功耗"的官方公开 API。本实现通过 AppleSMC 探测一组候选键（`PSTR`、`PDTR`、`PCHC`、`PSYS`、`PWRS`，候选列表由 `Sources/SMCBridge/SMC.c` 唯一定义）。

- **部分 Intel 机型 / 部分 macOS 版本**可以读到，此时显示真实瓦数；
- 读不到时回退为经验公式估算值（默认 TDP 45W，可在设置里调整），**UI 上会以 `~` 前缀标注以示区分**，这属正常现象，与该机固件未暴露功耗键有关，**并非程序错误**。

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

## 数据持久化

数据以 CSV 异步持久化（不阻塞界面）：

- 功率 / 电量日志：`~/Library/Application Support/MacBattery/power_log.csv`
- 电池健康日志：`~/Library/Application Support/MacBattery/battery_health_log.csv`（按「值变化」或「距上次记录超 6 小时」任一触发落盘）

---

## 结构

```
Sources/
├── MacBattery/
│   ├── main.swift                  # 入口
│   ├── AppSettings.swift           # 设置项持久化（含界面语言）
│   ├── FloatingPanel.swift         # 置顶透明穿透浮窗 + 位置
│   ├── PowerHUDView.swift          # 电量圆环 + CPU/RAM 半环 + 两行功率 UI
│   ├── PowerMonitor.swift          # 后台采样 + 结果发布（SMC/IOKit 不阻塞 UI）
│   ├── PowerLogger.swift           # 功率 / 电量 CSV 异步持久化
│   ├── PowerChartView.swift        # 历史功率图表
│   ├── PowerChartPanelController.swift
│   ├── Battery.swift               # 电量 + 充电功率 + 电压电流（IOKit 官方 API）
│   ├── BatteryHealthLogger.swift   # 电池健康采样与 CSV 落盘
│   ├── BatteryHealthChartView.swift# 电池健康图表
│   ├── BatteryHealthPanelController.swift
│   ├── SettingsView.swift          # 设置面板
│   ├── SettingsWindowController.swift
│   ├── LocalizationManager.swift   # 界面语言运行时状态（语言变化驱动重绘）
│   ├── Updater.swift               # 在线自动更新（GitHub Releases + DMG 下载）
│   ├── SMC.swift                   # AppleSMC 整机功率读取
│   └── SystemPower.swift           # 整机功率数据源（含估算 / 真实 helper 值）
├── MacBatteryCore/                 # 纯逻辑层（禁止 AppKit/IOKit/SwiftUI，可独立单测）
│   ├── Localization/               # 多语言引擎：语言解析、三级回退、区域化数字/日期
│   └── Resources/
│       ├── zh-Hans.lproj/Localizable.strings   # 简体中文（默认语言 / 回退目标）
│       └── en.lproj/Localizable.strings        # English
├── MacBatteryHelper/
│   └── main.swift                  # root helper 守护（真实整机功率）
└── SMCBridge/
    ├── SMC.c                       # AppleSMC 底层 C 读取
    └── include/SMC.h
Scripts/
├── install_helper.sh               # 安装 root helper
├── check_hardcoded_strings.py      # CI 守护：拦截界面层残留的硬编码文案
├── check_localization_keys.py      # CI 守护：键名一致性 / 占位符漂移 / 引用了不存在的键
└── make_icon.py                    # 生成应用图标
Resources/
└── AppIcon.icns                    # 应用图标
```

## 调整项

- **位置**：改 `FloatingPanel.swift` 中 `placePanel` 的 `margin` 与起点坐标。
- **尺寸/配色**：改 `PowerHUDView.swift` 的 `frame`、圆环线宽、`ringColor` 阈值。
- **刷新间隔**：改 `PowerMonitor.swift` 中采样节奏（含后台 timer）。