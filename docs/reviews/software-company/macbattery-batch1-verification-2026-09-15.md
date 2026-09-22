# MacBattery 第一批修复 · 独立验收报告

- 验收人：严过关（QA Engineer）
- 日期：2026-09-15
- 范围：工程师寇豆码第一批 6 项修复（U-01 / U-02 / U-05 / U-10 / U-04 / U-08），改动在**工作树、未 commit**
- 被测基线：tag v1.1.10，分支 `workbuddy/main-247e6f68`
- 方法：**纯静态审查 + 逻辑推演**（本机 Windows，无 Swift 工具链，**无法编译/运行/真机**）。凡涉及运行时行为者一律标注"需真机验证"。
- 改动清单（`git diff --stat`，工作树共 11 个文件）：
  `README.md`、`Battery.swift`、`FloatingPanel.swift`、`PowerHUDView.swift`、`PowerMonitor.swift`、`SMC.swift`、`SettingsView.swift`、`SystemPower.swift`、`MacBatteryHelper/main.swift`、`SMCBridge/SMC.c`、`SMCBridge/include/SMC.h`。

---

## ① 验收结论

**通过（可提交）。**

一句话理由：6 项修复全部落在声明的范围内，逐一静态核对无 P0/P1 新缺陷、无函数签名悬空调用、无锁死/漏解锁、无 CSV/接口破坏；仅存 3 条**非阻断**的轻微观察（1 条 P2 残量与真机强相关、2 条为既有/文档性）。

---

## ② 逐项验收结果

### U-01 加锁（SMC / SystemPower / Battery）—— **通过**

证据（文件:行）：
- `Battery.swift:13` 新增 `private static let lock = NSRecursiveLock()`；`:30-33` `markBatteryEvent()` 加锁 + `defer unlock`；`:69` `chargingStatus()` 临界区起始；`:100` 正常路径解锁；`:149-150` `health()` 加锁 + `defer unlock`。
- `SMC.swift:15` 新增锁；`:40-41` `systemWatts()` 整体持锁 + `defer unlock`。
- `SystemPower.swift:21` 新增锁；`:94-95` `cpuUsage()` 整体持锁 + `defer unlock`；`:26` `watts()` **不持本类型锁**（内部串行调用，见检查①）。

核对点：
- `chargingStatus()` **两条 return 路径均释放锁**：早期 guard（`Battery.swift:72-75`）显式 `lock.unlock()` 后 return；正常末尾（`:100`）解锁后 return。临界区内**无其它 return**。✅
- 三个锁（`BatteryReader.lock`/`SMCReader.lock`/`SystemPower.lock`）**从不跨类型同时嵌套持有**：`SystemPower.watts()`（`:27` 先 `SMCReader.systemWatts()` 返回→锁已 defer 释放；`:33` 再 `cpuUsage()` 取本类型锁），二者串行不交叠。✅
- 锁**绝不跨 `pmset` 子进程持有**：`Battery.swift:100` 先解锁，`:112` 才调 `pmsetBatteryStatus()`。✅

结论：**通过**（并发正确性仍需真机压测，见 ⑤）。

### U-02 pmset 超时与管道顺序 —— **通过**

证据：
- 缓存有效期 `2.0 → 5.0`：`Battery.swift:194`（`now - pmsetCacheTime < 5.0`）。
- 读管道先于等退出：`:221` `readDataToEndOfFile()` → `:222` `waitUntilExit()`。
- 新增 1.5s 看门狗：`:214-217` `DispatchWorkItem { if process.isRunning { process.terminate() } }` + `DispatchQueue.global(qos:.utility).asyncAfter(deadline: .now()+1.5, ...)`；`:223` `timeout.cancel()`。
- stdout/stderr 仍共用一个 `Pipe`：`:204-205`。
- 解析逻辑**未改**：`:226-233`（`AC Power` / `charging && !discharging` / `charging || finishing charge`）。

核对点：
- 看门狗终止子进程 → 管道 EOF → `readDataToEndOfFile()` 返回 → `waitUntilExit()` 立即返回；死锁风险消除。✅
- `terminate()` 后 `timeout.cancel()` 幂等；子进程 <1.5s 正常退出时 `cancel()` 阻止误杀。✅
- 锁语义：缓存读 `:193-198`（两分支均 unlock）、缓存写 `:236-239`；`catch { return nil }`（`:208-209`）发生在解锁**之后**，不持锁。✅
- 缓存 5.0s 与 `eventImmediateWindow` 2.5s（`Battery.swift:24`）无冲突：插拔时由 `:97` 主动置 `pmsetCache = nil` 强制刷新。✅

结论：**通过**。

### U-05 SMC 键单一数据源 + README —— **通过**

证据：
- C 侧唯一定义：`SMC.c:10-16` `kSMCPowerKeys[]`（PSTR/PDTR/PCHC/PSYS/PWRS）；`:18-20` `SMCPowerKeyCount()`；`:22-27` `SMCPowerKey(int)`（越界返回 `NULL`）。
- 声明：`SMC.h:68` `int SMCPowerKeyCount(void);`、`:70` `const char *SMCPowerKey(int index);`。
- 消费方：`SMC.swift:19-28` 由 `SMCPowerKeyCount()`/`SMCPowerKey(i)` 构建 `powerKeys`；`MacBatteryHelper/main.swift:37-44` 同样读取。
- README：`cd d:/Project/MacBattery` → `cd <MacBattery 工程目录>`；候选键 `EDR0` → `PSYS`；"读不到显示 `--`" → "回退估算、UI 以 `~` 标注"；新增 Gatekeeper 首次打开提示。

核对点：
- 三处键列表**现为同源**（C 表），顺序一致（PSTR→PDTR→PCHC→PSYS→PWRS）。✅
- `module.modulemap` 为 `export *`（已核对 `Sources/SMCBridge/include/module.modulemap`），新符号对 Swift 可见，**无需**改 modulemap。✅
- `SMC.c` 新增 `#include <stddef.h>`（`:4`），`NULL` 有定义来源。✅

结论：**通过**。

### U-10 估算值标注（`~` 前缀）—— **通过**

证据：
- `SystemPower.swift:11-16` 新增 `struct Reading { watts; isEstimate }`；`:26` `watts()` 返回 `Reading`；`:28/:31` 实测分支 `isEstimate:false`，`:36` 估算分支 `isEstimate:true`。
- 传递链：`Sampler.Frame.systemWattsIsEstimate`（`PowerMonitor.swift:21`）← `:40` 赋值；`PowerMonitor.systemWattsIsEstimate`（`:56`）← `:153` 赋值；`PowerHUDView.swift:172` `return monitor.systemWattsIsEstimate ? "~" + value : value`。
- **CSV 不变**：`PowerMonitor.swift:155-165` 仍只传 `systemWatts`（Double），`PowerLogger` 9 列表头与写盘逻辑（`PowerLogger.swift:115/168/255`）**未动**。✅

核对点：
- `~190.0`@scale=0.8 布局数学（检查⑥）✅，见下。
- `systemWattsIsEstimate` 仅 `@Published` 内存态，未写入 `UserDefaults`、未入 `PowerSample`，不破坏持久化/历史。✅
- 路径 `PowerChartView.swift:237` 的 `$0.systemWatts` 作用于 `PowerSample`（日志样本），**非** `SystemPower.watts`，不受签名变更影响。✅

结论：**通过**。

### U-04 面板定位（仅 a+b：单次 setFrame + 值比较过滤）—— **通过（含 1 条 P2 残量）**

证据：
- 单次 `setFrame`：`FloatingPanel.swift:91-98` 合并尺寸+原点，`panel.setFrame(NSRect(origin:newOrigin,size:newSize), display:true)`；删除原 `setContentSize` + `setFrameOrigin` 两步。
- `positionPanel` → `computeOrigin(size:)->NSPoint?`（`:103-127`）：纯计算、不触碰窗口；四角/自定义算法与旧实现**逐字一致**（`:110-126` vs diff 旧 `:229-246`）。
- `lastProgrammaticOrigin`（`:23`）在 `:97` 写、`:143-144` 无条件消费、`:145-149` ≤0.5pt 值比较过滤。
- **未做**越界项：无纯函数化 `PanelPosition` 枚举、无 `AppSettings` 改动（`AppSettings.swift`/`saveCustomPosition`/`rememberDrag` 均未改，见 `git status`）。✅

核对点：
- `NSScreen.main == nil` → `computeOrigin` 返回 nil → `?? panel.frame.origin`（`:92`）回落到当前原点（等于无位移）；若仍发 didMove，值与 `expected` 相同 → 被过滤。✅
- 值比较对"程序化移动"的过滤：见 ③-④ 的**残量分析**（P2）。结论仍为通过——残量只在"同一次运行内两次程序化位移早于异步观察者排空"且"AppKit 确对程序化 setFrame 发 didMove"的**双前置条件**下才触发，且非本次回归的主目标。

结论：**通过**（附 P2 残量，不阻断提交）。

### U-08 helper（autoreleasepool）—— **通过**

证据：
- `MacBatteryHelper/main.swift:22-25` `autoreleasepool { readSystemPowerWatts(); writePower(watts) }`，`:26` `sleep(interval)` 在池外。
- `signal`/JSON 输出**未改**：`:14-15`、`:50-59`；键读取改为同源 `SMCPowerKeyCount()/SMCPowerKey(i)`（`:37-44`）。

核对点：
- `autoreleasepool` 可用性：`import Foundation`（`:1`）已导入，Darwin 上可用。✅
- `sleep` 置于池外不会导致自动释放对象在池外产生（`sleep` 无 Foundation 分配）。✅

结论：**通过**。

---

## ③ 我要求你找的那 8 类问题 · 各自结论

1. **锁死面 / `chargingStatus` 每条 return 都解锁 —— 无问题。**
   两条 return 路径均解锁；临界区内无第二个 return；无任何线程在持 `BatteryReader.lock` 时调 `waitUntilExit()`；三把锁不跨类型同时嵌套。**无死锁、无漏解锁。**

2. **`chargingStatus` 行为等价 —— 等价。**
   旧逻辑 `if sinceEvent<window, let io=ioPSIsCharging() { isCharging=io; pmsetCache=nil }` 与新逻辑（临界区内 `eventImmediate=ioPSIsCharging()`；仅当非 nil 才 `pmsetCache=nil`；锁外 `if let io=eventImmediate`）**分支穷尽一致**：窗口内 + ioPS 非 nil → 走 io 并清缓存；窗口内 + ioPS 为 nil → 落 pmset 且不清；窗口外 → 落 pmset。调用次数亦同为 1 次。✅

3. **签名变更调用点完整性 —— 完整。**
   `SystemPower.watts` 唯一调用点 `PowerMonitor.swift:38`（grep 全仓确认）；返回 `Reading` 已就地取 `.watts/.isEstimate`。`positionPanel` 仅余文档注释（`FloatingPanel.swift:102`），无活跃调用。`systemWattsIsEstimate` 在 Frame/监控/视图三处闭环。**无悬空调用、无类型不匹配。**

4. **U-04 值比较盲点 —— 有 1 处残量（P2，见 ④-1）。**
   常规路径（程序化位移后无并发、或 AppKit 不发 didMove）安全；仅"同轮内 ≥2 次程序化 `setFrame` 早于异步观察者排空"且"AppKit 确实对程序化 setFrame 发 didMove"时，第 2 条通知会被误判为用户拖拽。**不阻断**，建议加固。

5. **C↔Swift 接口映射 —— 正确。**
   `int`→`Int32`（`SMCPowerKeyCount` 返回 `Int32`，`for i in 0..<count` 的 `i` 亦 `Int32`，与 `SMCPowerKey(Int32)` 一致）；`const char *`→`UnsafePointer<CChar>?`，`String(cString:)` 读取 NUL 结尾字面量（静态存储、生命周期覆盖进程）；`modulemap export *` 覆盖新符号；`SMCGetFloatValue(conn, key)` 形参 `const char*` 与实参匹配。**无误。**

6. **`~190.0`@scale=0.8 布局 —— 不溢出（通过）。**
   基数：`PowerHUDView.baseWidth = 58*scale + 2*(6*scale) = 70*scale`（`:15-19`），scale=0.8 → 56pt；内可视区 = 56 − 2×(6×0.8) = **46.4pt**。`systemValueText` 字号 = 12×0.8 = 9.6pt 粗体（`:98`），最宽串 `~190.0`（TDP=180 时估算上限 = 180×1.0 + 10 = 190.0）约 6 字形 ≈ 31pt，+ 间距 1.2 + 单位 `W` 5.2pt ≈ **35pt < 46.4pt**，余量 >10pt。**不溢出。**（比早前更保守的初判乐观；如需极窄屏稳健，可选把值字号降到 11×scale，非必需。）

7. **越界文件未被动 —— 未动。**
   `git status --porcelain` 仅 11 个声明内文件 `M`；`PowerLogger.swift`/`BatteryHealthLogger.swift`/`PowerChartView.swift`/`BatteryHealthChartView.swift`/`Updater.swift`/`Package.swift`/`.github/`/`AppSettings.swift` 均**不在**改动集。✅

8. **`Text` 内反引号（CSS/Markdown）—— 非缺陷，team-lead 的担忧不成立。**
   实际代码 `SettingsView.swift:46` 为 `Text("挂件上整机功率数字带 `~` 前缀时表示那是估算值；…")`。SwiftUI 字符串字面量走 `LocalizedStringKey`，**会解析 Markdown**；一对反引号 = 行内代码，渲染为"带 `~`（等宽）前缀"，**反引号本身被消耗、不显示**。用户看到的是"~"以示区分，**符合意图**。此条**无问题**。

**附加 2 项：**
- **`autoreleasepool` / `DispatchWorkItem` 导入可见性 —— 可见。** `MacBatteryHelper/main.swift` 与 `Battery.swift` 均 `import Foundation`；Apple 平台 Foundation 重新导出 Dispatch，`DispatchWorkItem` / `DispatchQueue.global(qos:)` 可解析（仓内 `PowerMonitor.swift` 已以 Foundation 使用 DispatchQueue，有先例）。✅
- **`props = retry` 未使用告警 —— 无告警，且为既有。** `Battery.swift:72` `var props` 在 `:77-79` 被读取，故不触发"never used"；其后的 `props = retry`（`:85`）为死存储，但 Swift 对局部死存储不告警。该结构与**改动前完全一致**（diff 显示 `props` 相关行属未改上下文），非本批引入。

---

## ④ 发现的新问题

### P2-1（新，真机强相关）`lastProgrammaticOrigin` 一次性消费在"连续程序化位移"下可能漏判

- 位置：`FloatingPanel.swift:97`、`:143-149`。
- 机理：观察者**读到即置 nil**，仅对**本条**通知做值比较。若在一次运行内、异步观察者排空之前发生 **≥2 次程序化 `setFrame`**（`lastProgrammaticOrigin` 被后者覆盖），第 1 条通知命中并被消费、置 nil；第 2 条通知 `expected == nil` 落入"按拖拽记录"分支（`:151`），把程序化位置写入 `hasCustom=true` → **角落锚定丢失**（即 U-04 想修的同一现象，可能间歇复现）。
- 触发前置条件（**两个同时满足**）：(a) AppKit 确实对程序化 `setFrame` 发出 `NSWindow.didMoveNotification`（**未验证**）；(b) 同轮内两次 `applySettings` 早于主队列观察者排空。二者叠加概率低。
- 可达性：`onChange` 仅在 `SettingsStore.commit()` 调用（`AppSettings.swift:64`，属性 setter 不触发）。菜单 `chooseCorner` 与 SwiftUI `SettingsView.onChange` 都存在 commit 触发路径，理论上可在同一轮产生 >1 次 `applySettings`（取决于 SwiftUI 事务时序）。
- 建议（任选其一，非阻断）：
  1. 观察者命中值比较时**不清空** `lastProgrammaticOrigin`（改为在 `applySettings` 覆盖 / 真实拖拽时清），使连续程序化通知整批被忽略；
  2. 或改用**代际计数**（`programmaticMoveGeneration += 1`）在观察者侧比对"自收到以来是否又有新的程序化位移"；
  3. 或观察者**忽略 `applySettings` 后极短窗口（如 250ms）内**的 didMove。

### P2-2（既有，非本批）`Battery.swift:85` `props = retry` 属死存储
- 位置：`Battery.swift:72/85`。功能无影响；属既有代码风格问题，不在 U 范围内，建议后续顺手清理（把 `var props` 改 `let props` 并删除赋值）。

### 说明：无 P0 / 无 P1 新问题。

---

## ⑤ 我无法确认 / 需真机验证的项（静态审查无法覆盖）

1. **AppKit 是否对程序化 `setFrame` 发 `didMove`**（决定 P2-1 是否真实可触发）——需真机打日志确认通知条数。
2. **视觉布局**：`~190.0` 在 scale=0.8/1.0/1.3 的实际渲染宽度与是否被圆角环裁切（我用字形度量估算，非像素级）。
3. **pmset 看门狗实效**：真实卡死/慢进程下 1.5s 终止与管道 EOF 行为。
4. **SMC/IOKit 实读**：`SMCPowerKey*` 在 Intel/Apple Silicon 各机型读到的键与数值；`chargingStatus` 并发下句柄重建的 use-after-free 是否彻底消除（需并发压测）。
5. **`~` 前缀实际观感**：估算/实测切换时 HUD 文本宽度跳变是否可接受。

---

## ⑥ 是否可提交 —— 建议

**建议：可提交（commit）。** 6 项修复自成闭环、范围合规、无阻断缺陷。

随附（可选、不阻塞）：
- 将 **P2-1** 作为**已知低概率残量**记入变更说明/后续任务，真机确认 didMove 行为后再决定是否加固（推荐按 ④-1 方案 1 做一次小改——成本极低、彻底闭合）。
- **P2-2** 记为技术债，随下一次清扫处理。
- 提交信息建议明确 3 处"看护点"：① pmset 缓存 2.0→5.0s；② `SystemPower.watts` 返回类型变更（Reading）；③ 程序化定位改为单次 `setFrame` + 值过滤。

---

### 附：本次验收所用证据命令
- `git diff --stat` / `git status --porcelain`（范围核验）
- `git diff -- <11 files>`（逐行核验）
- ripgrep：`SystemPower\.watts|computeOrigin|positionPanel|systemWattsIsEstimate|SMCPowerKey|chargingStatus\(|markBatteryEvent\(|BatteryReader\.health\(|cpuUsage\(|readDataToEndOfFile|readToEnd|autoreleasepool`
- 只读核对：`module.modulemap`（`export *`）、`AppSettings.swift`（onChange 语义）、`SMC.c/.h`、`PowerLogger.swift`（CSV 列）
