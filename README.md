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

---

## 结构

```
Sources/MacBattery/
├── main.swift          # 入口
├── FloatingPanel.swift # 置顶透明穿透浮窗 + 位置
├── PowerHUDView.swift  # 圆环电量 + 两行功率 UI
├── PowerMonitor.swift  # 每秒刷新数据
├── Battery.swift       # 电量 + 充电功率（IOKit 官方 API）
└── SMC.swift           # AppleSMC 整机功率读取
```

## 调整项

- **位置**：改 `FloatingPanel.swift` 中 `placePanel` 的 `margin` 与起点坐标。
- **尺寸/配色**：改 `PowerHUDView.swift` 的 `frame`、圆环线宽、`ringColor` 阈值。
- **刷新间隔**：改 `PowerMonitor.swift` 中 `Timer` 的 `1.0` 秒。