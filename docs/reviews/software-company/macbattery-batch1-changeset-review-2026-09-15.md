# MacBattery 第一批修复 · 变更说明与验收状态

- **范围**：改进项 **U-01（第 1 步）/ U-02 / U-04 / U-05 / U-08 / U-10**
- **状态**：**已实现 + 已独立验收（通过），改动全在工作树，未 commit、未 push**
- **规模**：11 个文件，`+264 / −68`
- **实现**：寇豆码（工程师）｜**验收**：严过关（QA 工程师）｜**汇编**：齐活林（主理人）
- **验收报告**：`macbattery-batch1-verification-2026-09-15.md`

> ⚠️ **本机为 Windows，无 Swift 工具链**，全部改动**未经编译、未经运行、未经真机验证**。验收为静态审查 + 逻辑推演。首次提交前请在 macOS 上跑一次 `swift build -c release`。

---

## 一、变更清单

| # | 改进项 | 文件 | 变更要点 |
|---|---|---|---|
| 1 | **U-01** 加锁 | `Battery.swift`、`SMC.swift`、`SystemPower.swift` | 三个类型各新增 `private static let lock = NSRecursiveLock()`，保护各自的静态缓存 |
| 2 | **U-02** `pmset` | `Battery.swift` | 缓存 `2.0s → 5.0s`；`readDataToEndOfFile()` 提前到 `waitUntilExit()` **之前**；新增 1.5s 看门狗 `terminate()` |
| 3 | **U-04** 面板定位 | `FloatingPanel.swift` | 新增 `lastProgrammaticOrigin`；两步动窗口合并为**单次 `setFrame`**；`positionPanel` → 无副作用的 `computeOrigin(size:)` |
| 4 | **U-05** 键同源 | `SMC.h`、`SMC.c`、`SMC.swift`、`MacBatteryHelper/main.swift` | 候选键提升为 C 侧唯一定义处，经 `SMCPowerKeyCount()` / `SMCPowerKey()` 共享 |
| 5 | **U-05** 文档 | `README.md` | 修 Windows 残留路径、键列表 `EDR0→PSYS`、"`--`" 文案；新增 Gatekeeper 首次打开说明 |
| 6 | **U-08** helper | `MacBatteryHelper/main.swift` | 主循环体包 `autoreleasepool`，`sleep` 留在池外 |
| 7 | **U-10** 估算标注 | `SystemPower.swift`、`PowerMonitor.swift`、`PowerHUDView.swift`、`SettingsView.swift` | 新增 `Reading{watts,isEstimate}`；估算时 HUD 数字前置 `~`；设置面板补说明 |

**未改动**（已逐条核对）：`PowerLogger.swift`、`BatteryHealthLogger.swift`、`PowerChartView.swift`、`BatteryHealthChartView.swift`、`Updater.swift`、`Package.swift`、`.github/`、`AppSettings.swift`。

---

## 二、验收结论

**通过（可提交）。** 6 项全部落在声明范围内，无 P0/P1 新缺陷，无悬空调用、无漏解锁、无 CSV/接口破坏。

已确认的关键点：
- `chargingStatus()` 两条 `return` **均已解锁**，临界区内无第二条 return；三把锁**从不跨类型嵌套**；**无任何线程持锁阻塞在 `waitUntilExit()`**。
- `chargingStatus()` 的三分支重写（锁内暂存 `eventImmediate` + 锁外判定）与原逻辑**逐条等价**，`pmsetCache = nil` 触发条件未漂移。此结论由**主理人独立复核** + QA 独立枚举，双方一致。
- `SystemPower.watts` 改签名后**唯一调用点**已同步；`Sampler.Frame` 新字段无遗漏构造处。
- `pmset` 解析逻辑逐字未改（1.1.10 刚修好的 `finishing charge` 行为未受影响）。
- `power_log.csv` 的 **9 列格式未变**（估算标记仅内存态，不入盘）。
- C↔Swift 类型映射正确（`int→Int32`、`const char*→UnsafePointer<CChar>!`），`module.modulemap` 的 `export *` 覆盖新符号。

### 验收中闭合的一处漏洞（U-04 加固）
原实现的"读到即置 nil"在**一轮内发生两次程序化 `setFrame`** 时，第二条 `didMove` 通知会因 `expected == nil` 落入"按拖拽记录"，写回 `hasCustom = true` —— **正好复现 U-04 本要修的"角落锚定丢失"**。

已改为 **"命中则忽略并保留标记，不命中才清除"**：
- 两次程序化位移 O1→O2 + 两条通知 → 均取 `expected = O2`、窗口 origin 亦为 `O2` → **两条都被正确忽略**；
- AppKit 若**不发**通知 → 标记保留至首次真实拖拽（值不符）才清除，**无错误行为**；
- 用户拖走再拖回原坐标 → 第一次拖拽即清除标记，**不会误吞**第二次。

> 该 2 行改动由 QA 提出、工程师实现、**主理人复核**（此 delta 未经独立 QA 二次验收，规模 2 行、语义互斥且已被 QA 预先枚举）。

---

## 三、提交信息建议

```
Fix concurrency safety, pmset blocking, estimate labeling and panel anchoring

U-01 给 BatteryReader / SMCReader / SystemPower 的静态缓存加锁（NSRecursiveLock）：
     主线程存在 5 条硬件访问入口（启动首拍 / 每次插拔 / 健康日志启动采样 /
     60s 周期采样 / 打开健康窗口），原先仅靠"只在后台串行队列调用"的注释约束，
     休眠唤醒时 rebuildService() 的 IOObjectRelease 可能与另一线程读并发。
U-02 pmset 子进程：先读管道再等退出（消除管道写满互等）、加 1.5s 看门狗超时、
     缓存 2s→5s（fork 由约 30 次/分降至约 12 次/分）。
U-04 面板定位：程序化移动改"命中保留 / 不命中清除"的值过滤，
     两步动窗口（setContentSize + setFrameOrigin）合并为单次 setFrame，
     消除"尺寸已变、原点未随"的中间态，修复角落锚定丢失。
U-05 SMC 候选功耗键提升为 SMCBridge 唯一定义处（原先三处不同源，README 已写错）；
     README 修正多处漂移并补 Gatekeeper 首次打开说明。
U-08 root helper 主循环加 autoreleasepool（原先以 launchd 守护常驻时内存单调增长）。
U-10 整机功率估算值在 UI 上以 ~ 前缀标注（原先用户会把估算当实测）。
```

**提交前请特别留意三处「看护点」**（会改变既有行为）：
1. **`pmset` 缓存 2s → 5s** —— 充电状态在极端时序下最多滞后 5s（原先 2s）。
2. **`SystemPower.watts` 返回类型 `Double` → `Reading`** —— 破坏性签名变更（仓内已全部同步）。
3. **程序化定位改单次 `setFrame` + 值过滤** —— 窗口几何应用路径改变。

---

## 四、尚未闭环（需真机确认，均不阻塞提交）

| # | 待确认 | 决定什么 |
|---|---|---|
| 1 | AppKit 是否对**程序化** `setFrame` 发出 `didMove`（Apple 无契约保证） | U-04 定性：确认则现有修复有效；不确认则该 bug 本不存在（但代码在两种情形下均安全） |
| 2 | `~190.0`（非 Intel 机型 + TDP 拉至近上限 180）在 `scale=0.8` 下的**实际渲染宽度** | 见下节"边界情形" |
| 3 | `pmset` 看门狗在真实卡死/慢进程下的表现 | U-02 超时是否真的生效 |
| 4 | 休眠唤醒 + 插拔的**并发压测**下 use-after-free 是否彻底消除 | U-01 的实际效果（建议连续"休眠-唤醒-插拔"20 次并观察日志） |
| 5 | 编译 + 运行（`swift build -c release`） | 全部改动 |

---

## 五、一处边界情形（P3 视觉，未修，待实测）

**`~190.0` 在 `scale = 0.8` 下可能轻微压到内环。**

- 文字净宽（正确算法）：可视底盘 `58×0.8 = 46.4pt`，内环 `.padding(innerRingInset)` 内缩 `4.4pt`、描边半宽 `1.2pt` → **净宽 = 46.4 − 2×5.6 = 35.2pt**。
- 文本 `~190.0`（6 字符，字号 `12×0.8 = 9.6pt` bold rounded）估算宽度 **约 34–37pt** → **处于边界**，可能压到内环约 1–2pt。

> 说明：本项曾一度被误判为"余量 >10pt"（用了 46.4pt 这个**内容区**宽度而非**净宽**）。经主理人复核，净宽应为 35.2pt。该情形需"非 Intel 机型 + 用户把 TDP 拉到接近滑块上限 180"同时成立，属视觉瑕疵。
>
> **建议**：不在无实测的情况下凭估算改字号（用一个未验证的改动换另一个）。真机截图确认后，如确有碰撞，一行即可缓解（估算态该 `Text` 改用 `11 * scale`）。

---

## 六、下一批（未开始）

| 批次 | 内容 |
|---|---|
| 第二批 | **U-01 第 2/3 步**（`scheduleSample()` 改入队 + 健康日志硬件读取移出主线程 + `dispatchPrecondition` 护栏）、**U-03**（历史数据静默丢失）、**U-11**（退出路径清理与落盘兜底）、**U-06**（CI 版本号一致性） |
| 第三批 | **U-09**（`MacBatteryCore` + test target + CI test job，**须在动图表之前做**）、**U-13**（删除两处死代码，成本近零，建议尽早）、**U-07**（图表基础设施抽取）、**U-12**、`FloatingPanel` 拆分 |

**特别提醒**：**U-13** 待删的 `refreshOnce()`（`PowerMonitor.swift:103`）与 `saveCustomPosition()`（`AppSettings.swift:68`）是**现成引信** —— 前者接线即产生新的主线程采样入口（U-01 形态），后者接线即触发 U-04 的重入面。建议在第二批一并清掉。

**U-09 的验收前置**：U-04 的几何纯函数 `originFor(corner:visibleFrame:size:margin:)` + 覆盖矩阵（四角 × scale{0.8,1.0,1.3} × margin 正负）尚未落地，因此 **U-04 目前不得标记为"已验证/关闭"**。
