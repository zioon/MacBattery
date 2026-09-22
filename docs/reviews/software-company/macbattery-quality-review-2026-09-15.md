# MacBattery 质量与测试评审报告

- 评审人：严过关（QA 工程师，software-qa-engineer）
- 评审对象：`MacBattery` @ 分支 `workbuddy/main-247e6f68`，最新 tag `v1.1.10`
- 评审方式：**纯静态代码阅读**（环境为 Windows，无法 `swift build` / `swift test`，所有结论均为静态推断）
- 范围：`Package.swift` 3 个 target、`Sources/MacBattery/` 16 个文件、`Sources/MacBatteryHelper/main.swift`、`Sources/SMCBridge/*`、`.github/workflows/build-dmg.yml`、`README.md`、`CHANGELOG.md`
- 硬约束遵守情况：**未修改任何源码文件**（仅新增本报告）

---

## 一、质量现状判断

整体风险等级 **中高**：功能实现成熟（CHANGELOG 20+ 条修复显示迭代充分），但**并发模型存在系统性缺陷**——`Sampler`/`BatteryReader`/`SMCReader`/`SystemPower` 的静态缓存被多处注释声明为"只在后台串行队列访问"，而实际上**至少在 2 个入口会在主线程执行同一套采样路径**，休眠唤醒（句柄失效重建）时存在对同一 IOKit/SMC 句柄的跨线程关闭与使用，属于"概率性触发、触发即崩溃或读数错误"的类型，且极难在测试中复现。最危险的区域是 `PowerMonitor.scheduleSample()`（`Sources/MacBattery/PowerMonitor.swift:121`）与 `BatteryReader.rebuildService()`（`Sources/MacBattery/Battery.swift:213`）的组合。其次是**用户数据的静默丢失面**：磁盘句柄打开失败、单次 UTF-8 分块解码失败都会让整段历史无声消失，而项目里没有任何日志、断言或监控，出了事用户和开发者都无从定位。最可能出事的场景是：**长时间挂机 + 休眠唤醒后插拔电源**（同时命中句柄重建竞态、`pmset` 子进程阻塞、回填覆盖三处缺陷）。

---

## 二、缺陷风险清单

### 汇总表

| 编号 | 位置（文件:行） | 触发条件（可复现操作） | 影响 | 优先级 |
|---|---|---|---|---|
| P0-1 | `PowerMonitor.swift:121-124`（可达调用点 `:89,:177`；`:104` 为死代码）+ `Sampler` `:5-7` / `Battery.swift:6` / `SMC.swift:8` 的不变量假设 | 任意时刻插拔电源；或应用启动瞬间（两条路径均已核实可达） | 主线程与采样队列并发读写同一批静态缓存；休眠唤醒时 `IOObjectRelease`/`SMCClose` 与另一线程的读并发 → **use-after-free 崩溃** 或 CPU%/功率读数错乱 | **P0** |
| P0-2 | `Battery.swift:144-174`（`:159` `waitUntilExit()`、`:161` `readToEnd()`） | 启动首拍采样（2.5s 事件窗口外）；任何 `chargingStatus()` 走到 pmset 分支 | 在**主线程**同步等待子进程 → 启动卡顿；采样队列被阻塞 → 采样停摆；`waitUntilExit()` 先于读管道 → 输出超管道容量时**死锁** | **P0** |
| P1-1 | `Battery.swift:14,20-22,70,73,141-142,146,171-172` | 电源事件（主线程）与采样（队列）交错 | `lastEventRefTime` / `pmsetCache` 无同步跨线程读写，充电状态可能瞬时误判（旧坑复发） | P1 |
| P1-2 | `FloatingPanel.swift:57-65`（`:61-64`） | 窗口控制器析构（终止/关闭） | `deinit` 中 `Task { [weak self] }` 捕获已析构的 self → `monitor.stop()`/`healthLogger.stop()` **永不执行**，`powerSourceSource` 不摘除，timer 泄漏 | P1 |
| P1-3 | `FloatingPanel.swift:90-131` + `AppSettings.swift:76-84` | 菜单栏「位置」选任一四角 | `setFrameOrigin` 触发 `didMove` → `rememberDrag` 把预设角写成了"自定义位置"，`hasCustom` 被置真 → 位置菜单**无勾选项**，下次启动用旧坐标 | P1 |
| P1-4 | `MacBatteryHelper/main.swift:18-22` | root helper 常驻数小时以上 | `while true` 无 `autoreleasepool` → 常驻 root 守护**内存单调增长** | P1 |
| P1-5 | `PowerLogger.swift:151-152,171-188`（`:177`）, `BatteryHealthLogger.swift:197-198,216-233` | 磁盘满 / 无写权限 / App Support 目录创建失败 | 句柄打开失败被 `try?` 吞掉、`writeSamples` 直接 `return` → **历史数据 100% 静默丢失，无任何提示与日志** | P1 |
| P1-6 | `PowerLogger.swift:212`、`BatteryHealthLogger.swift:258` | 分块倒读时块边界落在非 ASCII 字节序列中间 | `String(data:encoding:.utf8)` 返回 nil → `break` → **整段历史读不回来**（图表空白），与 1.1.9 修过的"曲线为空"症状同源 | P1 |
| P2-1 | `PowerLogger.swift:88-97`（`:94`） | 启动瞬间：磁盘回填未完成时已有实时采样 | `self.samples = history` 直接覆盖已攒的实时点（健康日志 1.1.9 已修，功率日志**漏修**） | P2 |
| P2-2 | `PowerLogger.swift:28-31` + `PowerChartView.swift:71` | 重启后点「24h」/「全部」 | 内存容量 20 万点，回填上限仅 4 万点 → 重启后"24h"实际只显示约 5.5h 回填 + 新采样，与文档/预期不符 | P2 |
| P2-3 | `PowerLogger.swift:71`、`BatteryHealthLogger.swift:112` | 缓冲到达上限后（约 24h 连续运行） | 每 0.5s 一次 `removeFirst(1)` 是 O(n) 搬移（约 12MB memmove）→ 主线程周期性抖动 | P2 |
| P2-4 | `Battery.swift:116-120` | 机型 `DesignCapacity` 缺失（0） | 回退用 `MaxCapacity` 当设计容量 → 健康度恒显示 ≈100%，误导用户 | P2 |
| P2-5 | `Battery.swift:35` + `PowerHUDView.swift:63` | `CurrentCapacity > MaxCapacity`（异常固件值） | 百分比 >100 → `trim(to: progress)` 传入 >1，进度弧渲染异常 | P2 |
| P2-6 | `Updater.swift:273`（`:271-274`），`:170-174`，`:197-204` | 下载中磁盘满 / `~/Downloads` 只读 / GitHub 403 限流 | 临时文件中转用 `try?` 静默失败；限流与 404 合并为同一提示；无重试、无断点续传 | P2 |
| P2-7 | `Updater.swift:224,235,245` | `.accessory` 策略下自动更新弹窗（尤其启动时） | `NSAlert.runModal()` 在无 Dock、非激活进程上可能不获得焦点/被其它窗口遮挡 | P2 |
| P2-8 | `FloatingPanel.swift:91` | 多显示器，副屏上使用挂件 | `NSScreen.main` 取的是"含菜单栏/主窗口的屏"，改位置/改尺寸会把挂件**拽回主屏**，而非用户所在屏 | P2 |
| P2-9 | `SMC.swift:43,53` | 命中固件异常返回值分支 | `effectiveKey!` 强制解包（当前逻辑安全但极脆弱，改动即崩） | P2 |
| P2-10 | `SMC.swift:46-53` | 有效键被读出 0（休眠唤醒） | 每拍 `SMCClose` + `SMCOpen` 两个系统调用，且 `effectiveKey` 不重置 → 唤醒后每 0.5s 空转重建连接 | P2 |
| P2-11 | `SystemPower.swift:47-54` + `MacBatteryHelper/main.swift:43` | helper 与 app 版本不一致 / SMC 读回 NaN·inf | JSON 无时间戳，app 无法识别**过期**数据；`"{\"systemPower\":\(watts)}"` 在 NaN/inf 时生成非法 JSON | P2 |
| P2-12 | `FloatingPanel.swift:84-85` + `:47` | 穿透开启（默认）后想拖动/右键 | 默认 `passthrough=true` 时窗口 `ignoresMouseEvents=true`，挂件**完全不可交互**且 `isMovableByWindowBackground=false`，只能靠菜单栏 | P2 |
| P2-13 | `AppSettings.swift:41` | 先用 `swift run` 再用 `.app`（或反之） | `UserDefaults.standard` 域不同 → 设置**不共享**，用户感觉"设置丢了" | P2 |
| P2-14 | `PowerChartView.swift:596-609`、`:297-315` | 打开历史图表 + 24h 窗口 | 每 0.5s 主线程 `O(系列数 × 可见样本数)` 全量重算（峰值约 1.2M 次运算/帧） | P2 |
| P2-15 | `.github/workflows/build-dmg.yml:48` | `workflow_dispatch` 手动触发 | tag 覆盖分支不成立 → 产物版本号停在 base64 里的硬编码 `1.0.0`，应用内更新比对失效 | P2 |
| P2-16 | `Package.swift:9-25`；无 `Tests/`；`.github/workflows/build-dmg.yml` | 任何改动 | **零测试、零 lint、CI 无 test job** → 回归全靠人肉 | P2 |
| P2-17 | `main.swift:21-23` | 终端 Ctrl+C 退出（README 推荐用法） | 不触发 flush → 最多 1s 未落盘样本 + `ioQueue` 上排队写入丢失 | P2 |
| P2-18 | `README.md:39,86,90` | 阅读文档 | 已知的文档/实现漂移（Windows 路径、候选键、`--` 占位）未修，仍是错误信息 | P2 |
| P2-19 | `FloatingPanel.swift:77,81-82` + `:87` | 任一次设置提交（含**拖动 TDP 滑块**，`SettingsView.swift:81` 每次 `onChange` 都 `commit()`） | `applySettings()` 每次都**新建 `NSHostingView`** 并整树重建（`:77,:81`），且**分两步动窗口**（`:82` `setContentSize` → `:87`/`:117` `setFrameOrigin`）→ 视图 churn + 中间帧（旧原点/新尺寸）；而 TDP 变更**本不驱动 HUD 布局**，纯属浪费 | P2 |
| P2-20 | `AppSettings.swift:68-73`、`PowerMonitor.swift:103-105` | 阅读代码 / 未来接线 | 两处**死代码**：`saveCustomPosition` 与 `refreshOnce` 全仓无调用点（grep 核实）。`saveCustomPosition` 恰好是"会触发 `commit()`/re-layout"的那个版本，**一旦有人把它接到 `didMove` 观察者上（替换 `rememberDrag`），P1-3 的重入面立刻成立** | P2 |

---

### P0 展开说明

#### P0-1 「只在串行队列访问」的不变量被打破（跨线程访问 IOKit/SMC 缓存）

**位置**

- `Sources/MacBattery/PowerMonitor.swift:121-124` `scheduleSample()` —— 在调用它的线程上**同步**执行 `performSampling()`：

  ```swift
  private func scheduleSample() {
      tdpBox.value = settings.tdpWatts
      performSampling()          // ← 不在 sampleQueue 上，就地执行
  }
  ```

- 三个调用点全部是 `@MainActor` 上下文，但**当前只有两条可达**（已核实调用关系）：
  - `PowerMonitor.swift:89`（`start()` 内，启动首拍）—— **可达**
  - `PowerMonitor.swift:177`（`powerSourceChanged()`，电源插拔回调）—— **可达**
  - `PowerMonitor.swift:104`（`refreshOnce()`）—— **当前不可达**：`refreshOnce()`（`:103`）在全仓**无任何调用点**（已用 grep 核实，属死代码）。但它是内部 `func`，注释明确写着用途"供顶层独立刷新（例如设置里调整 TDP 后立即更新）"，一旦被接上（例如 SettingsView 真的调用它），**立即成为一个新的主线程采样入口**，属于"埋着的引信"，故仍计入本缺陷的入口面
- 被打破的声明式不变量：
  - `PowerMonitor.swift:5-7`：「所有读取均为 nonisolated，且只被后台串行采样队列调用」
  - `Battery.swift:6`：「注册表读取仅在后台串行采样队列中调用，缓存的 service 句柄无需额外加锁」
  - `SMC.swift:8`：「本枚举只在后台串行采样队列中被调用，因此静态缓存无需额外加锁」
- 第二个主线程入口：`BatteryHealthLogger.swift:51-60` `start()` 在 `@MainActor` 上**同步**调用 `sample(force: true)`（`:59`）→ `BatteryReader.health()`（`:87`）→ `currentService()`（`Battery.swift:109`）。
- 共享可变状态清单：
  - `BatteryReader.cachedService`（`Battery.swift:10`），读写 `:204-210`，**释放+重匹配** `:213-218`
  - `SMCReader.conn`（`SMC.swift:21`），打开 `:27`，**关闭+重开** `:47-48`
  - `SMCReader.effectiveKey`（`SMC.swift:23`）
  - `SystemPower.lastCpuTicks`（`SystemPower.swift:58`），读写 `:62-66`
  - `BatteryReader.lastEventRefTime`（见 P1-1）
  - `TDPBox.value`（`PowerMonitor.swift:183-188`），主线程写 `:122,:132`、队列读 `:128`

**触发条件（可复现操作序列）**

1. 挂机运行（保持默认设置，穿透开启）。
2. 休眠 → 唤醒（AppleSmartBattery 句柄失效 → `chargingStatus()` 首次读三属性全 0 → 命中 `Battery.swift:53` → `rebuildService()` → `IOObjectRelease(cachedService)`）。
3. 在唤醒后 `BatteryHealthLogger` 的 60s 心跳（主线程）或电源事件回调（主线程）恰好与采样队列的 0.5s tick 重叠。

队列 tick 与主线程 tick 的重叠是概率性的，但 0.5s × 60s 的双周期在长时间运行下**必然发生**；而 `rebuildService` 只在"读失败"时触发，正好集中在休眠唤醒这个高风险窗口。

**影响**

- 最坏：`IOObjectRelease`/`SMCClose` 释放的句柄正被另一线程使用 → **use-after-free / `kIOReturnNotOpen` 崩溃或读数全 0**（用户可见：挂件数字突然变 `0`/`--`，或应用直接闪退）。
- 中度：`SystemPower.lastCpuTicks` 被两线程交替更新 → `cpuUsage()` 的 tick 增量失真，CPU% 出现跳变/长期为 0。
- 轻度：`TDPBox.value` 撕裂（虽在 x86_64 上对齐 Double 读写实际原子，但这是未定义行为，Swift 内存模型不保证）。

**修复建议（最小侵入）**

1. 把 `scheduleSample()` 改为只做入队，禁止就地采样：

   ```swift
   private func scheduleSample() {
       tdpBox.value = settings.tdpWatts
       sampleQueue.async { [weak self] in self?.performSampling() }
   }
   ```

   这样三条路径（启动 / 电源事件 / 手动刷新）全部回到串行队列，注释中的不变量重新成立。
2. `BatteryHealthLogger.sample()` 中的 `BatteryReader.health()` 需要与采样同队列：把 `BatteryReader` / `SMCReader` 的访问统一封装到一个 `nonisolated` 的 `HardwareReader` 串行队列（或 `NSLock` 保护的 `static let lock`），health 与 power 采样都走它。
3. `TDPBox` 用 `os_unfair_lock` / `NSLock` 包裹 `value` 的读写（成本可忽略，每 0.5s 两次）。
4. 在 `Package.swift` 里打开 Swift 6 严格并发（或至少在 Xcode 里开 `-strict-concurrency=complete`）——这些缺陷编译器本可以报出来（`Package.swift:4-25` 目前无任何 `swiftSettings`）。

#### P0-2 `pmset` 子进程：同步阻塞 + 无超时 + 读取顺序倒置

**位置**

- `Sources/MacBattery/Battery.swift:144-174`，关键行：
  - `:148-153` 每次新建 `Process` + `Pipe`，**每次 `standardOutput` 和 `standardError` 都指向同一个 Pipe**
  - `:159` `process.waitUntilExit()` —— 在**调用线程**上同步阻塞
  - `:161` `pipe.fileHandleForReading.readToEnd()` —— **在 waitUntilExit 之后**才读
- 调用链：`Sampler.sample`（`PowerMonitor.swift:26`）→ `BatteryReader.chargingStatus()`（`:74`）→ `pmsetBatteryStatus()`。

**触发条件**

1. 启动首拍：`FloatingPanelController.init`（`FloatingPanel.swift:40`）→ `PowerMonitor.start()` → `scheduleSample()` → 主线程 `performSampling()` → `lastEventRefTime == 0`（`:70` 的 `sinceEvent` 极大）→ 走 pmset 分支 → **在主线程 fork/exec `pmset`**。冷启动时 `pmset -g batt` 首次执行通常在几十到几百毫秒。
2. 长时间挂机后 `pmsetCache` 过期（2s）且任意线程触发的采样。

**影响**

- 启动时主线程被阻塞（浮窗首帧延迟、App 启动"卡一下"）。
- 在采样队列上阻塞 → 采样节拍被拉长，`DispatchSourceTimer` 错过触发（会被合并，但采样率下降 → 历史曲线出现空洞、插拔感知变慢，这正是 1.0.9 已经修过一次的问题类型回归）。
- 死锁面：`waitUntilExit()` 在读取管道**之前**，如果 `pmset` 输出超过管道缓冲区（macOS 默认约 64KB，见 `fcntl F_SETPIPE_SZ`），子进程写满阻塞、父进程等退出 → 双方互等。当前 `pmset -g batt` 输出极小，实际不触发，但这是一处**结构性隐患**，且 `Pipe` 未设上限（任务书关注点 4 成立）。
- 无超时：`pmset` 若因系统异常挂起，采样线程永久卡死，且没有任何日志。

**修复建议**

1. 先读管道再等退出（或使用 `readDataToEndOfFile()` 后台读 + `terminationHandler`）：

   ```swift
   let out = pipe.fileHandleForReading.readDataToEndOfFile()   // 必须在 waitUntilExit 之前
   process.waitUntilExit()
   ```

2. 加超时（`DispatchWorkItem` + `process.terminate()`，例如 1.5s）。
3. 把 pmset 调用搬到独立队列并加"在途"标志，避免与采样队列耦合；或改用 `IOPSCopyPowerSourcesInfo` 的 `kIOPSPowerSourceStateKey` + `kIOPSIsChargingKey` 完全替代 pmset（1.1.0 已经证明 IOPS 与菜单栏同源），把子进程降级为可选诊断手段。
4. 采样路径上不要在主线程调用 `chargingStatus()`（依赖 P0-1 的修复）。

---

### P1 展开说明

#### P1-1 `lastEventRefTime` / `pmsetCache` 跨线程无同步

- `Battery.swift:20-22` `markBatteryEvent()` 由 **主线程** 调用（`PowerMonitor.swift:176`），写 `lastEventRefTime`（`:14`）。
- `Battery.swift:70` 在 **采样队列** 读 `lastEventRefTime`；`:73` 在采样线程写 `Self.pmsetCache = nil`。
- `pmsetCache` / `pmsetCacheTime`（`:141-142`）读写位于 `:146,:171-172`，同样没有同步。
- 影响：`lastEventRefTime` 撕裂（x86_64 上实际原子，但语义是未定义）；更实质的是 `pmsetCache = nil` 与 `pmsetBatteryStatus()` 的 `if let cached`（`:146`）跨线程读写 —— 与 P0-1 同源。这正是 CHANGELOG 里 1.0.9 / 1.1.0 反复修过的"充电状态误判"区域的第 N 次复发风险。
- 修复：随 P0-1 一并把硬件读取串行化；或把这几个字段收进一个 `struct BatteryStateCache`，用 `NSLock` 保护；`markBatteryEvent` 改为向采样队列 `async` 投递事件。

#### P1-2 `deinit` 里用 `Task { [weak self] }` 调用 `stop()` → 永不执行

```swift
deinit {
    if let observer = moveObserver { NotificationCenter.default.removeObserver(observer) }
    Task { @MainActor [weak self] in
        self?.monitor.stop()        // ← self 已在析构中，weak 引用必然为 nil
        self?.healthLogger.stop()
    }
}
```

`FloatingPanel.swift:57-65`。`deinit` 执行期间对象引用计数已为 0，`[weak self]` 解引用必为 nil；即便不为 nil，`Task` 也晚于 `deinit` 返回，若进程随后退出则 Task 永不执行。

**影响**：`PowerMonitor.stop()`（`PowerMonitor.swift:92-100`）与 `PowerLogger.stop()`（`PowerLogger.swift:57-61`）不执行 →

- `sampleSource` 未 `cancel()`（`:93`）→ 活动的 `DispatchSourceTimer` 不被释放，持续空转（handler 内 `[weak self]` 为 nil 只是空转，但仍是常驻 CPU 唤醒 + 对象泄漏）；
- `powerSourceSource` 未 `CFRunLoopRemoveSource`（`:96-99`）→ 电源事件源仍注册，其 context 是 `passUnretained(self)`（`:162`）→ 理论上存在悬垂指针回调；
- `PowerLogger.stop()` 的最终 `flushPending()`（`:60`）不执行 → **最后一段未落盘样本丢失**。

**修复建议**：不要在 `deinit` 里做异步清理。改为：

1. `AppDelegate.applicationWillTerminate`（`main.swift:21-23`）显式调用 `windowController?.shutdown()`；
2. `shutdown()` 是 `@MainActor` 同步方法，内部直接 `monitor.stop()` / `healthLogger.stop()` / 摘除 `moveObserver`；
3. 或让 `FloatingPanelController` 持有 `monitor` 的生命周期并在 `windowWillClose` 时停表。

#### P1-3 选四角位置立即被"自定义位置"覆盖

- `FloatingPanel.swift:242-247` `chooseCorner` 设置 `hasCustom = false` → `commit()` → `onChange` → `applySettings()`（`:70`）→ `positionPanel()`（`:87`）→ `panel.setFrameOrigin(origin)`（`:117`）。
- `NSWindow.setFrameOrigin` 会发出 `NSWindowDidMoveNotification`；而 `observeWindowMove(panel)`（`:48`，在首次 `applySettings` **之后**注册）监听该通知（`:120-131`），回调里调用 `settings.rememberDrag(...)`（`:127-129`）→ `AppSettings.swift:76-84` 内部把 `hasCustom = true` 并写入 UserDefaults。

**触发条件**：任意一次「位置」→ 选「左下角」。

**投递语义（已确定，与架构评审交叉核对后收敛）**

`observeWindowMove` 用 **`queue: .main`** 注册块式观察者（`FloatingPanel.swift:121-125`）。块式观察者注册到非 nil 队列时，回调被**投递到该 OperationQueue** 执行，而**不在 `NSNotificationCenter.post` 的调用栈内内联**。因此：**无论 AppKit 内部对程序化 `setFrameOrigin` 是同步还是异步 post，到达 `rememberDrag` 时 `applySettings()`/`positionPanel()` 的栈早已返回** —— 即"同步投递导致同一栈帧内重入"这一更坏的形态**不会发生**。

另有一条独立证据：`rememberDrag`（`AppSettings.swift:76-84`）**不调用 `commit()`/`onChange()`**（逐行核实：只写 4 个字段 + 3 个 UserDefaults key），所以**即便**假设投递是同步的，也不会重入 `applySettings()`。
> ⚠️ 第二条理由是**脆弱**的：将来若有人给 `rememberDrag` 补一个 `commit()`，重入面立即成立。这正是"状态源分离"值得做的理由。

**影响（修正后的精确表述）**

因投递延后，`chooseCorner()`（`:242-247`）在 `setFrameOrigin()` 之后**同步**调 `rebuildMenuCheckmarks()`（`:246`），此刻 `hasCustom` 仍为 `false` → **菜单勾选当场是正确的**。问题不在"立刻"，而在于**状态已与真实情况脱节，下次重建才暴露**：

1. 设置面板长期误显"已在自定义位置"（`SettingsView.swift:24-28`，判定 `store.hasCustom`）；
2. **角落锚定丢失** —— `hasCustom == true` 后 `positionPanel`（`:99-100`）改走 `customX/customY` 分支：此后 `chooseSize()` 改尺寸、或换分辨率/显示器时，窗口**不再重新贴角**，而是停在旧坐标 → 尺寸变化后挂件与屏幕边缘的间距漂移，分辨率变化时可能落到屏外；
3. 菜单勾选在**下一次**重建（任一菜单操作 / 重启）后变为全空（`:165` 判定恒假）。

**修复建议（按稳健性排序，已与架构评审对齐）**

1. **值比较（首选，可先落地）**：`positionPanel` 程序化设原点时把目标原点存为 `lastProgrammaticOrigin`；观察者回调里若观测值与它相等（随即清空）→ 忽略，不写 `hasCustom`。判据是**值**而非"标志何时清零"，因此**免疫同步/异步投递差异**，且在"会 post / 不会 post"两种情形下都无副作用（不 post 时永不触发）。**QA 附加细化两点**：
   - 比较加**容差**（建议 ≤ 0.5pt），防 AppKit 在 backing scale / 舍入上造成 1 像素级偏差导致误判；
   - 明确一个已知可接受的边界：若用户把窗口**拖回并恰好停在**该程序化原点，这一次 `didMove` 会被吞掉（`hasCustom` 不置真）。概率极低且自恢复，但应在代码注释里写明，避免后人误判为 bug。
2. **`PanelPosition` 枚举做单一真相源（结构性并列首选）**：把 `hasCustom` + `cornerRaw` + `customX/Y` 四个字段收敛为 `.corner(Corner)` / `.custom(x:y)`。**注意**：枚举消除的是**状态散落**，它**不回答"这次移动是谁发起的"**（`didMove` 通知里没有来源信息），因此**仍须配合第 1 条的值比较**（或显式来源标记）才能完整成立。
3. **抑制标志（次选/补充，不可单独使用）**：`设标志 → setFrameOrigin → DispatchQueue.main.async { 清标志 }` 的时序**没有保证**——观察者块与清零块都排在主队列，先后取决于入队时刻；若 AppKit 延后一拍才 post，则清零块可能先跑 → 抑制失效。故**仅作辅助**。
4. **抽 `PanelLayout` 模块**，把"程序化定位"与"用户拖拽记录"两侧收敛到一处（长期方向）。

> ⚠️ 该条成立的前提是「程序化 `setFrameOrigin` **会 post** `NSWindowDidMoveNotification`」。Apple 文档未对此作契约保证，双方均无法从静态代码断定 → **需实机确认**（见第六节第 1 项）。确认前本条的"影响"应表述为**高度可疑（机制清晰、证据为静态推断）**，**不得表述为"已复现"**。若确认"会 post" → P1 中优先项；若确认"不会 post" → 降 P2 并仅保留状态建模价值。**值比较修法（第 1 条）无论证实与否均可先落地且无副作用。**

#### P1-4 root helper 的 `while true` 缺少 `autoreleasepool`

`MacBatteryHelper/main.swift:18-22`：

```swift
while true {
    let watts = readSystemPowerWatts()
    writePower(watts)
    sleep(interval)
}
```

顶层代码的 `while true` 没有每轮 `autoreleasepool { }`。`writePower`（`:42-52`）内部使用 `String.write(toFile:)` 与 `withCString`，会经 Foundation 产生自动释放对象；在 root 常驻守护里堆只会单调增长（该进程 `KeepAlive=true`，`install_helper.sh:43-44`，几乎不会重启）。

**影响**：一个长期占用 root 资源、内存持续上涨的守护进程 —— 既是稳定性问题，也是安全/口碑问题（用户会对"常驻 root 进程"非常敏感）。

**修复建议**：

```swift
while true {
    autoreleasepool {
        writePower(readSystemPowerWatts())
    }
    sleep(interval)
}
```

同时建议：`signal(SIGTERM) { _ in exit(0) }`（`:14-15`）在信号处理器里调用 `exit` 是 async-signal-unsafe 的（虽常见），可改为设置 `sig_atomic_t` 标志位、在主循环里判断。

#### P1-5 磁盘写入失败被完全静默

`PowerLogger.swift:171-188` `fileHandle()`：

```swift
if !FileManager.default.fileExists(atPath: url.path) {
    FileManager.default.createFile(atPath: url.path, contents: nil)   // :175 返回值被忽略
}
guard let h = try? FileHandle(forWritingTo: url) else { return nil }  // :177 失败无痕
```

`PowerLogger.swift:151-152`：`guard let h = fileHandle() else { return }` —— 静默返回，`batch` 被 `flushPending` 从 `pending` 移除（`:83`）后**永久丢失**且上层不知情。`BatteryHealthLogger.swift:197-198,216-233` 是同一复制粘贴的同一缺陷。

**触发条件**：磁盘满；`~/Library/Application Support/MacBattery` 因权限/沙盒/迁移助理异常不可写；用户手动把 `power_log.csv` 设为只读。

**影响**：产品两大卖点（历史功率曲线、电池健康曲线）**在用户毫不知情的情况下彻底失效**，且因为无日志，事后无法诊断。这是"静默失败"里后果最重的一处。

**修复建议**

1. `fileHandle()` 失败时通过 `os.Logger`（`Logger(subsystem: "com.zioon.macbattery", category: "io")`）记录 `errno`；
2. `writeSamples` 失败时把 `batch` 回填到 `pending`（保留上限，例如最多 5000 点），或至少置一个 `@Published var lastWriteError: String?` 让设置面板能显示"历史保存失败"；
3. `createFile` 的返回值参与判断；
4. 启动时自检：能创建/打开 `power_log.csv` 就绪；否则在 UI 上给一次性提示。

#### P1-6 单个分块解码失败 → 整段历史读不回来

`PowerLogger.swift:212`：

```swift
guard var text = String(data: data, encoding: .utf8) else { break }
```

`BatteryHealthLogger.swift:258` 完全相同。倒读是**字节偏移**分块（`chunk = 1 << 20`，`:199`/`:245`），块边界是任意字节位置 —— 不是行边界、也不是字符边界。一旦某块的起点落在一个 UTF-8 多字节字符中间，整块 `String(data:encoding:.utf8)` 返回 nil，`break` 直接放弃**全部**结果，返回部分（通常为空）数组。

**触发条件**：CSV 内容全部是 ASCII 数字，正常不会命中；但一旦公司层面往 CSV 追加任何非 ASCII（例如把表头或新增列写成中文、或用户用编辑器把文件另存为含 BOM/中文注释），命中率高。更现实的是：**该防御本身是脆的**，且没有降级路径。

**影响**：重启后历史图表全空，与用户已反馈修过两次的"曲线为空"症状完全一致（1.1.5 / 1.1.9 的 CHANGELOG 条目），运维上会被误判为"上次的 bug 又回来了"。

**修复建议**

1. `guard let text = String(data: data, encoding: .utf8) else { break }` 改为 `continue`/`offset` 回退：解码失败时把该块的起点向前/后挪 1 字节重试（最多 3 次），或改用 `String(decoding: data, as: UTF8.self)`（容错替换非法字节，不返回 nil）——这是同一 API 家族里更适合"逐块拼接"的选择；
2. 由于 CSV 语义上就是"以 `\n` 分隔的 ASCII 行"，建议直接按 `\n` 做字节级切分（`data.split(separator: 0x0A)`）避免任何字符串解码；
3. 解码失败/达到 `readSoFar < 48 << 20` 上限（`:204`/`:250`）时必须记日志，否则"读了但没有"和"没读"无法区分。

---

### P2 说明（择要）

- **P2-1 回填覆盖**：`PowerLogger.swift:88-97`，completion 里只校验 `generation`（`:93`），随后 `self.samples = history`（`:94`）直接替换。而 `BatteryHealthLogger.swift:138-152` 的 `merge(history:new:)` 是 1.1.9 专门加的修复。**同一类 bug 只修了一半**。建议把 `merge` 抽成共用函数，两个 logger 共用。
- **P2-2 回填上限不一致**：`memoryCapacity = 200_000` / `historyBackfill = 40_000`（`PowerLogger.swift:28-31`）。UI 提供「24h」预设（`PowerChartView.swift:71`），但重启后只有 4 万点 ≈ 5.5h 可回填。要么把回填上限提到与内存容量一致，要么把「24h」预设文案改成「最近记录」。
- **P2-3 环形缓冲退化为 O(n)**：`PowerLogger.swift:71` `samples.removeFirst(samples.count + 1 - Self.memoryCapacity)` 在满载后每拍搬移一次。CHANGELOG 1.0.9 修的是"整数组复制"，这处是另一处 O(n)。建议攒够 2000 个再一次性 `removeFirst(2000)`，或改用真正的环形缓冲（`rotation` 索引）。
- **P2-4 健康度假 100%**：`Battery.swift:116-120`，`designCap = firstPositive(DesignCapacity, MaxCapacity)`，当 `DesignCapacity == 0` 时用 `MaxCapacity` 兜底，`healthPercent = AppleRawMaxCapacity / MaxCapacity * 100 ≈ 100%`。建议此时把 `healthPercent` 记为 0 并在 UI 上显示「设计容量不可读」，而不是显示一个体面的假数字 —— 电池健康度是用户做换电池决策的依据。
- **P2-5 百分比越界**：`Battery.swift:35` 未夹取 0...100；`PowerHUDView.swift:63` `.trim(from: 0, to: progress)`。建议 `min(1, max(0, progress))`。
- **P2-6 / P2-7 更新流程**：`Updater.swift:271-274` 用 `try?` 把系统临时文件搬到自建临时文件，若搬迁失败，`finishDownload`（`:190-208`）会拿到不存在的 URL 再 `moveItem` 失败 → 用户看到"保存安装包失败"但根因被吞。`:170-174` 把 403（限流）与 404（不存在）合并成一句"GitHub 返回 403"。建议：403 单独提示"接口限流，请稍后再试"；搬迁失败回落到直接在原 location 读取 `Data` 写目标文件；对"磁盘满/无权限"分别提示。
- **P2-8 多屏**：`FloatingPanel.swift:91` `NSScreen.main` 对 `.accessory` 无 key window 的应用等价于"含菜单栏的屏"。改尺寸/改角时会把挂件拉回主屏。建议记录挂件所在屏（`panel.screen` 或按 `customX/Y` 反查 `NSScreen.screens` 中 frame 包含该点的屏），并在该屏坐标系内计算四角。
- **P2-9 / P2-10 SMC**：`SMC.swift:43,53` 的 `effectiveKey!` 建议改 `guard let`；`:46-53` 建议失败时把 `effectiveKey` 重置并做指数退避（例如连续失败后降频重探），否则唤醒后每拍两次系统调用空转。
- **P2-11 helper JSON**：`MacBatteryHelper/main.swift:43` 字符串插值在 `watts` 为 `NaN`/`inf` 时产出非法 JSON；建议 `watts.isFinite ? watts : 0`，并在 JSON 里加 `"ts"` 字段，app 侧（`SystemPower.swift:47-54`）校验时间戳新鲜度（例如 >5s 视为过期回退估算）。
- **P2-12 穿透默认值**：`AppSettings.swift:45` 默认 `passthrough = true`，`FloatingPanel.swift:84-85` 于是初始即 `ignoresMouseEvents = true` + `isMovableByWindowBackground = false`。新用户第一次运行会完全不知道挂件能用菜单栏交互。建议首次启动默认 `passthrough = false`，或在设置里加一行引导文案。
- **P2-13 UserDefaults 域**：`AppSettings.swift:41` 使用 `UserDefaults.standard`。`swift run` 的 domain 是进程名，`.app` 是 `com.zioon.macbattery`，两者不共享。建议显式 `UserDefaults(suiteName: "com.zioon.macbattery")`。
- **P2-14 图表主线程开销**：`PowerChartView.swift:596-609` 每 series 内层 `while i < sampleEnd`，`buildBands()` 在每次 body 求值时执行（`:164`）。24h 窗口 + 7 系列时约 120 万次运算/帧 × 2 帧/s。建议把桶平均结果按 `(startIndex, endIndex, valueMin, valueMax)` 缓存，只有输入变化时才重算。
- **P2-15 CI 版本号**：`.github/workflows/build-dmg.yml:48` 的条件 `[ "${GITHUB_REF_NAME#v}" != "$GITHUB_REF_NAME" ]` 在 `workflow_dispatch`（`:8`）时 `GITHUB_REF_NAME` 是分支名（如 `main`），不以 `v` 开头 → 跳过覆盖 → 产物停留在第 38 行 base64 里的 `1.0.0`。建议：version 改为从一次显式输入或从最近 tag 读取，而不是只认 `GITHUB_REF_NAME`。
- **P2-16 零测试**：`Package.swift:9-25` 只有 3 个 target，**没有 test target**；仓库内**没有 `Tests/` 目录**（已用全仓 glob 核实）；CI 无 test job。详见第三节。
- **P2-17 Ctrl+C 丢数据**：`main.swift:21-23` 只 `close()` 窗口，README（`:61`）推荐 Ctrl+C 退出，SIGINT 直接终止进程，`ioQueue` 上排队的写入与 `pending` 一并丢失。
- **P2-18 已知文档漂移**（沿用主理人上一轮结论，均已在代码中核实）：
  - `README.md:90` 写候选键 `PSTR、PDTR、PCHC、PWRS、EDR0`，`SMC.swift:12-18` 实为 `PSTR、PDTR、PCHC、PSYS、PWRS`；
  - `README.md:86` 写"读不到时显示 `--`"，但 `SystemPower.swift:17-20` 有估算回退，且 `PowerHUDView.swift:168` 只有在 `<= 0` 时才显示 `--` —— 实际几乎总有值；
  - `README.md:39` 残留 `cd d:/Project/MacBattery`；
  - `README.md` 未提示 ad-hoc 签名（`.github/workflows/build-dmg.yml:55`）导致的 Gatekeeper 首次打开限制。
- **P2-19 设置变更时的视图 churn 与"两步动窗口"**：`applySettings()`（`FloatingPanel.swift:70-88`）在**每次** `onChange` 都执行 `NSHostingView(rootView: PowerHUDView(...))`（`:77`）并 `panel.contentView = hosting`（`:81`）→ 整棵 HUD 视图树重建。触发频率最高的路径是 **TDP 滑块拖动**（`SettingsView.swift:81` 每 `onChange` 一次 `commit()`），而 TDP 只影响 `PowerMonitor` 的估算输入、**不参与 HUD 布局**，因此这些重建是纯开销。同一函数还**分两步**改窗口几何：`:82` `setContentSize`（保持旧原点、改尺寸 → 中间态）与 `:87`→`:117` `setFrameOrigin`（再改原点）。建议：① `hosting` 只建一次、设置变更仅更新 `PowerHUDView` 的 `scale`（或改用 `NSHostingView.rootView` 赋值）；② 把尺寸与原点**合并为一次 `setFrame(_:display:)`**（见附录 B 第二轮：这同时消除 P1-3 的"多次 `didMove`"不确定性）；③ TDP 变更不触发 `applySettings`。
- **P2-20 两处死代码是"埋着的引信"**：`saveCustomPosition`（`AppSettings.swift:68-73`）与 `refreshOnce`（`PowerMonitor.swift:103-105`）全仓无调用点。二者不是普通死代码——**它们恰好是各自"危险版本"**：`saveCustomPosition` 调 `commit()`（会 re-layout），而实际在用的 `rememberDrag`（`:76-84`）刻意**不**调 `commit()`；`refreshOnce` 会在主线程下次采样（P0-1）。建议：**要么删除，要么在注释里写明"为何不可直接接线"**，否则后人"顺手接上"就会引入缺陷。

---

### 对主理人上一轮关注点的核实结论（避免误判为缺陷）

| 关注点 | 核实结果 | 判定 |
|---|---|---|
| `IOServiceGetMatchingService` 的 `cachedService` 从不释放是否泄漏 | `Battery.swift:204-210` 只匹配一次并缓存，`rebuildService():213-218` 会 `IOObjectRelease` 后重匹配。进程生命周期内**最多存在 1 个句柄** | **非泄漏**（有界）。真正的问题是它的跨线程访问（P0-1），不是句柄数量 |
| `PowerLogger.generation` 能否覆盖所有重置竞态 | 能覆盖"重置前已发出的回填"，`PowerLogger.swift:93` 校验通过 | 重置路径**基本正确**；`clearDisk` 与 `write` 的先后由 ioQueue 串行保证（`:112`），FIFO 语义下"先写后删"净效果正确。**无 P0/P1 级重置竞态** |
| `readRecentHistory` 的"非首块丢弃首行"逻辑 | 逐块 `text = data + leftover`、`leftover = lines.first`、`lines.dropFirst()`（`PowerLogger.swift:213-221`）是标准且**正确**的跨块行拼接实现 | 逻辑正确。真正的问题是 `:212` 的整块解码失败（P1-6）与"恰好切在多字节字符中间"（同上） |
| CSV 重启后覆盖历史 / 重复表头（1.1.7 已修） | `fileHandle():180` `seekToEnd()` + `:183-186` 非空即 `headerWritten = true` | **已正确修复**，未回归 |
| `PowerLogStore.handle` 文件句柄生命周期 | 仅在 ioQueue 上读写；`clearDisk` 关闭并置 nil（`:134-136`） | 生命周期**正确**；仅缺进程退出时的兜底关闭与失败日志（P1-5） |
| `UpdateChecker` 的 `URLSession` 持有关系 | `session` 是强引用属性（`Updater.swift:95,107`），delegate 是 self → **循环引用**（session 强持有 delegate）。`UpdateChecker` 由 `FloatingPanelController` 持有至进程退出 | 有界泄漏，**非 P0**。建议改用 `URLSession(configuration:)` + completion-handler API，或显式 `invalidateAndCancel()` |
| helper 写文件 `atomically: true` 是否真原子 | 是（同目录临时文件 + rename） | **正确**，且意外地缓解了 `/tmp` 符号链接攻击（rename 替换链接本身而非目标）。风险面仅剩"信息泄露：任意本地用户可读走电功耗"，**低危** |
| `Amperage` 符号 / `chargeding` 相关旧坑 | `Battery.swift:63-90` 的判定链（IOPS 窗口 → pmset 权威 → 兜底）与功率"严格跟随 `isCharging`"（`:87`）与 CHANGELOG 1.1.1/1.1.8 描述一致 | **已正确修复** |

---

## 三、测试策略

### 3.1 现状评估

- **测试数量：0**。`Package.swift:9-25` 无 `.testTarget`；全仓无 `Tests/` 目录。
- **无静态检查**：无 `.swiftlint.yml`、无 `.swift-format`、无 `swift-format` 配置。
- **CI 无测试**：`.github/workflows/build-dmg.yml` 只有一个 `build-and-release` job（`:13-88`），只有构建与打包。
- 结论：**这个项目的回归防线目前 100% 依赖人工点击**，而 CHANGELOG 显示 20+ 次修复中有至少 4 次是"同一区域的反复翻车"（充电状态判定 1.0.9→1.1.0→1.1.7→1.1.10；图表空白 1.1.5→1.1.9）。这正是缺测试的典型征兆。

### 3.2 分层测试方案

#### 第 1 层：可纯函数化 → 直接单测（不需要任何抽象，收益最高）

| 待测逻辑 | 位置 | 需要的改造 | 建议用例 |
|---|---|---|---|
| 版本比较 | `Updater.swift:64-79` | 无（`isNewer` 已是 `static`，只需 `@testable import`） | `v1.1.10 > v1.1.9`（关键：字符串比较会判错）；`1.10 > 1.9`；`1.1.10 > 1.1.9`；`v1.1.9-beta` 视为 `1.1.9`；`""` 不更新；`latest` 不更新；`1.1` vs `1.1.0` 相等 |
| 功率估算公式 | `SystemPower.swift:17-20` | 抽出 `static func estimatedWatts(tdp:usage:) -> Double`（纯函数，去掉 SMC/helper 依赖） | `u=0 → tdp*0.05+7`；`u=1 → tdp+10`；`u` 越界夹取；`tdp=0` |
| 电量配色插值 | `PowerHUDView.swift:140-163` | 已 `static`；把返回 `Color` 改为同时暴露 RGB 元组更易断言 | `-1 → 红`；`1.5 → 青绿`；`0.2/0.4/0.6/0.8` 恰好等于 stop 色；`0.1` 在两 stop 之间线性 |
| 1-2-5 刻度步长 / 右轴 nice 取整 | `PowerChartView.swift:319-340, 904-915` | 从 `private` 提到 `internal` 或抽到 `ChartMath` | `niceStep(span:0) == 1`；单调性 `span↑ → step` 不减；`niceViewport(0,0) == (0, 1)`；`niceViewport(57.3,58.1)` 稳定不变（这是 1.1.3/1.1.5 反复调的区域） |
| 像素分桶平均 | `PowerChartView.swift:583-636` | 抽出 `bucketAverages(samples, startE, endE, bucketCount, value:) -> [Double?]` | 0 样本 → 全 nil；1 样本 → 1 桶有值；全部同时间戳 → 只落 1 桶；窗口平移时同一历史时刻落在同一桶（绝对锚定的核心断言） |
| 环形缓冲裁剪 | `PowerLogger.swift:67-76` | 抽出 `trimmed(_ samples:, capacity:)` | 容量边界 `count == capacity`、`count == capacity+1` |
| 四角定位计算 | `FloatingPanel.swift:90-118` | 抽出 `originFor(corner:visibleFrame:size:margin:) -> NSPoint` | 四个角 × 正 margin × 负 margin（大尺寸时 `20 - 6*scale` 仍为正） |
| CSV 行编解码 | `PowerLogger.swift:165-169, 234-257`、`BatteryHealthLogger.swift:211-214, 278-297` | 从 `private` 提到模块内可见 | 9 列/6 列往返；列数不足 → nil；epoch 为 0/负数/`"epoch"`/`"1.7e9"`；`levelPercent` 缺失 → -1；旧 5 列文件 |
| 跨块行拼接 | `PowerLogger.swift:193-232` | 抽出 `mergeChunk(text:leftover:isFirstBlock:) -> (lines:[Substring], leftover:Substring)` | 边界切在行中间；切在多字节字符中间；文件只有表头；文件只有一个不完整行；UTF-8 非法字节 |

> 这一层**不建议等重构**：立即可以先把上面这些函数复制到新 target 里做第一版测试，即便暂时是"复制实现"也比 0 测试好；随后用一次重构让生产代码调用同一份实现。

#### 第 2 层：需要协议抽离才能测（把硬件换成假对象）

| 依赖 | 建议协议 | 用它可测 |
|---|---|---|
| `BatteryReader`（`Battery.swift:7-227`） | `protocol BatteryReading { func level() -> Int; func chargingStatus() -> (...); func health() -> BatteryHealth? }` | `Sampler.sample` 全部分支；`BatteryHealthLogger.sample` 的 force/changed/baseline 三分支（`:96-105`）；健康度 0 容量边界 |
| `SMCReader.systemWatts` + `SystemPower.readHelperPower` | `protocol SystemPowerSource { func watts(tdp:usage:) -> Double }` | 三级回退优先级（SMC > helper > 估算，`SystemPower.swift:11-20`） |
| `pmset` 子进程 | `protocol CommandRunning { func run(_ path:[String]) throws -> String? }` | 5 种 pmset 文案（`discharging` / `AC Power; charging` / `finishing charge` / `charged` / 空输出）+ 超时 + 抛错，全部离线可测（`Battery.swift:144-174`） |
| `PowerLogStore` / `BatteryHealthLogStore` | `protocol LogStoring`（`write` / `clearDisk` / `readRecent`） | `PowerLogger` 的 `reset` / `flushPending` / `backfill` 竞态（用可控延迟的假 store 精确复现 P2-1） |
| CPU/内存读取 | `protocol SystemMetricsReading { func cpuUsage() -> Double; func memoryUsage() -> Double }` | `PowerMonitor.apply` 映射；`cpuUsage` 首次调用返回 0 的行为 |
| 定时器/时钟 | 注入 `schedule(after:interval:block:)` 与 `now: () -> Date` | 采样节拍、`BatteryHealthLogger` 的 6 小时基线（`:103`）不必真等 6 小时 |

抽离顺序建议：**先 `LogStoring` + `CommandRunning`**（这两处的 bug 面最大：P1-5/P1-6/P2-1/P0-2），再 `BatteryReading`（P0-1 的并发断言）。

#### 第 3 层：只能实机手工 / 集成验证

- SMC 真实键值探测（`PSTR`/`PSYS`… 在不同 Intel 机型、不同 macOS 版本的可读性）；
- IOKit 电源事件回调的时机与线程（`PowerMonitor.swift:161-172`）；
- 休眠唤醒后句柄失效与重建（P0-1 的触发条件本身）；
- 菜单栏 `NSStatusItem`、`.accessory` 策略下的弹窗焦点（P2-7）；
- 多显示器 / 分辨率变化 / Spaces；
- Gatekeeper 首次打开、launchd helper 安装与卸载；
- 24h 长时间挂机的内存曲线（P2-3、P1-4）。

### 3.3 让 `swift test` 跑起来的最小改造清单

目标：**最小侵入**，不动 `main.swift`，不改现有业务逻辑。

1. **`Package.swift`**（唯一必改的既有文件）—— 新增 1 个 library target + 1 个 test target：

   ```swift
   targets: [
       .target(name: "SMCBridge", path: "Sources/SMCBridge"),
       .executableTarget(name: "MacBatteryHelper", dependencies: ["SMCBridge"], path: "Sources/MacBatteryHelper"),
       // 新增：纯逻辑，零 AppKit/IOKit 依赖，可被测试
       .target(name: "MacBatteryCore", path: "Sources/MacBatteryCore"),
       .executableTarget(name: "MacBattery", dependencies: ["SMCBridge", "MacBatteryCore"], path: "Sources/MacBattery"),
       // 新增：测试
       .testTarget(name: "MacBatteryCoreTests", dependencies: ["MacBatteryCore"], path: "Tests/MacBatteryCoreTests")
   ]
   ```

   > 为什么不直接 `@testable import MacBattery`：那是 executable target，含 `main.swift` 顶层代码，SwiftPM 5.7 下测试 executable target 的链接行为不稳定（顶层代码/symbol 冲突）。抽出 `MacBatteryCore` 是最小且长期正确的做法。

2. **新增 `Sources/MacBatteryCore/`（4 个小文件，纯搬迁）**
   - `VersionCompare.swift` ← 从 `Updater.swift:62-79` 搬；
   - `ChartMath.swift` ← 从 `PowerChartView.swift:319-340, 583-636, 904-915` 搬出 pure 版本；
   - `CSVCodec.swift` ← 从 `PowerLogger.swift:165-169, 193-232, 234-257` 与 `BatteryHealthLogger.swift:211-214, 278-297` 合并出通用编解码（顺带修 P1-6）；
   - `PowerEstimate.swift` ← 从 `SystemPower.swift:17-20` 抽 `estimatedWatts(tdp:usage:)`。

3. **回改 4 处调用点**（每个 1-3 行）：`Updater.swift` / `PowerChartView.swift` / 两个 Logger / `SystemPower.swift` 改为调用 Core 里的实现。这是全部侵入量。

4. **`Tests/MacBatteryCoreTests/`** 覆盖 3.2 第 1 层表格。

> 如果需要测 `PowerLogger` 的竞态（P2-1、P1-5），把 `LogStoring` 协议与 `PowerLogger` 一起放进 `MacBatteryCore`（`PowerLogger` 目前依赖 `Combine` 与 `@MainActor`，不依赖 AppKit/IOKit，可以放下）。这是第二阶段的 2 个文件搬迁。

### 3.4 CI 集成建议（`build-dmg.yml` 最小改动）

```yaml
jobs:
  test:                                   # 新增 job
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: swift test
        run: swift test --parallel
        timeout-minutes: 20

  build-and-release:
    needs: test                           # 新增：测试不过不发版
    runs-on: macos-14
    steps: ...                            # 其余保持不变
```

注意事项（macos-14 是 arm64，且 CI 机器**没有电池**）：

- 只有 `MacBatteryCore` 的纯测试能在 CI 跑；任何触碰 `IOPSCopyPowerSourcesInfo` / `IOServiceGetMatchingService` / `pmset` 的测试必须显式 skip（`XCTSkipIf`），否则在 CI 上会返回 0 或空而"假绿"。
- 建议加一条轻量的静态检查步骤（见第三节 C），并把它并入 `test` job，`needs` 一次即可。
- `swift test` 默认构建全部 target（含 executable），若遇到 `main.swift` 相关的构建顺序问题，可用 `swift test --filter MacBatteryCoreTests`。
- 另建议给 `build-and-release` 的 `swift build` 加 `SWIFT_TREAT_WARNINGS_AS_ERRORS=1`（先只对 `MacBatteryCore`）以固化代码质量。

### 3.5 发布前手工冒烟测试清单

| # | 操作序列 | 预期结果 |
|---|---|---|
| 1 | 双击 `.app` 首次启动（未经 Gatekeeper 放行） | 弹出"无法验证开发者"，右键-打开后可运行；**记录实际提示文案**（README 未写，需确认 P2-18） |
| 2 | 启动后观察浮窗 | 出现在屏幕右上角，透明、无边框、无 Dock 图标，10s 内三处数字（整机 W / 充电 W / 电量环）有值且每秒级刷新 |
| 3 | 观察启动是否卡顿 | 浮窗 300ms 内出现（验证 P0-2 的主线程 pmset 是否造成可见延迟） |
| 4 | 插电源（浮窗可见时） | ≤1s 内出现 ⚡ 与充电 W、`x.xV · x.xA`；电量环颜色/发光变化 |
| 5 | 拔电源 | ≤1s 内 ⚡ 消失、充电 W 归 0、电压电流变 `--V · --A`（**不要**残留充电功率） |
| 6 | 充到 100% 后保持插电 | 显示"已充满"语义：`isCharging=false`、充电 W≈0，但**不出现**"放电中"（验证 `finishing charge` 分支） |
| 7 | 合盖 10s 后开盖 | 所有数字在 2s 内恢复合理值，**不出现** 0 / `--` 长期停留（验证 P0-1 句柄重建） |
| 8 | 系统休眠 5 分钟后唤醒 | 同上；连续唤醒 5 次、每次观察 10s（这是 P0-1 最可能暴露的序列） |
| 9 | 菜单栏 → 历史图表…（⌘G） | 窗口打开、有曲线、右轴刻度稳定（连点 10 次不跳变） |
| 10 | 历史图表滚轮缩放 / 拖拽 / Option 缩放右轴 | 曲线只平移不形变；固定窗口下曲线静止（1.1.5 断言） |
| 11 | 历史图表切换 5m/30m/1h/24h/全部 | 每个窗口都有数据；「全部」包含重启前历史 |
| 12 | 关闭图表 → 重启应用 → 重开图表 | 历史曲线**非空**且时间连续（验证回填 + P2-1 + P1-6） |
| 13 | 同一操作连续做 5 次重启 | 每次重启后 `power_log.csv` 行数**单调增加**，无重复表头、无异常时间戳（1.1.7 断言） |
| 14 | 菜单栏 → 电池健康…（⌘H） | 顶部 4 项指标有值；「实时容量」随电量变化（改电量后 ≤5s 刷新） |
| 15 | 健康窗口 → 重置数据（确认） | 曲线清空；`battery_health_log.csv` 变为空或重建（表头一条） |
| 16 | 历史窗口 → 重置数据（确认） | 曲线清空，CSV 清空；随后新采样正常追加且**只有一份表头** |
| 17 | 菜单栏 → 位置 → 依次选四个角 | 挂件移动到对应角；**「位置」菜单应显示当前角被勾选**（验证 P1-3）；重启后仍在所选角 |
| 18 | 拖动挂件到自定位置 → 重启 | 回到自定位置；「位置」菜单无勾选但设置面板提示"已在自定义位置" |
| 19 | 菜单栏 → 大小 → 小/中/大 | 圆形底盘缩放，位置仍贴原角（间距不变）；**不被拽到主屏**（多屏时验证 P2-8） |
| 20 | 菜单栏 → 鼠标穿透 开/关 | 开启后鼠标点击能穿透到下层窗口、挂件不可拖动；关闭后可直接拖动 |
| 21 | 系统深色 ↔ 浅色模式切换 | 挂件配色在两种模式下都可读（黑底半透明 + 白字，浅色桌面下是否足够对比） |
| 22 | 副屏：把挂件拖到副屏，切主屏为副屏（系统设置） | 挂件不丢失、不跑到屏外 |
| 23 | 多桌面（Spaces）：切到另一个桌面 | 挂件在**所有**桌面可见（`.canJoinAllSpaces`）；图表窗口只在原桌面 |
| 24 | 设置 → 拖动 TDP 滑块 → 观察整机 W | 数值随之变化（若 SMC/helper 不可用，仅估算路径生效）；滑块拖动不卡顿 |
| 25 | 菜单栏 → 检查更新…（手动） | 有明确结果文案；发现新版本时自动下载 DMG 到「下载」并弹窗 |
| 26 | 断网后检查更新 | 20s 内给出失败提示（`Updater.swift:105`），按钮恢复可用 |
| 27 | 用 `sudo ./Scripts/install_helper.sh` 安装 helper | `cat /tmp/macbattery_power.json` 有非零 `systemPower`；挂件整机 W 变为真实值 |
| 28 | 卸载 helper 后重启 app | 自动回落到估算值，**不崩溃、不显示 0** |
| 29 | 挂机 24h（可加速到 8h 观察趋势） | 内存不单调增长；`top` 观察 CPU 占用稳定（验证 P2-3、P2-14） |
| 30 | `swift run` 后 Ctrl+C 退出，再启动 | 不崩溃；CSV 未损坏（验证 P2-17 的实际损失量） |

---

## 四、可测试性 / 质量门禁建议

### 4.1 SwiftLint / swift-format：需要，但要"精准启用"，不要一把梭

**结论：建议引入 SwiftLint + swift-format**，因为本项目的问题集中在"静默失败 + 跨线程共享可变状态 + 巨型类型"，前两者需要 review 规则兜底，后者需要体量规则强制拆分。

**建议 `.swiftlint.yml`（只开"能落在这个项目具体代码上"的规则）**：

```yaml
disabled_rules:
  - identifier_name        # 项目用 Swift 常规命名，且大量 UI 常量，别折腾
  - todo
opt_in_rules:
  - force_unwrapping        # ← 直接对应 SMC.swift:43,53 的 effectiveKey!
  - force_try
  - force_cast
  - empty_count
  - explicit_init
  - redundant_nil_coalescing
  - closure_body_length
  - file_length
  - type_body_length
  - function_body_length
  - cyclomatic_complexity
line_length:
  warning: 140              # 当前代码最宽约 130，先别制造噪声
  error: 200
  ignores_comments: true    # 中文注释按字符算会误伤
file_length:
  warning: 600
  error: 1000               # PowerChartView.swift 915 行 → 立即告警但不阻断
type_body_length:
  warning: 400
  error: 700
function_body_length:
  warning: 80
  error: 150                # 命中 readRecentHistory / buildBands
cyclomatic_complexity:
  warning: 15
  error: 25                 # 命中 chargingStatus / buildBands / niceViewport
custom_rules:
  no_silent_try_optional:
    name: "禁止静默 try? 用作落盘/句柄"
    regex: '(FileHandle|createFile|moveItem|removeItem|write\(toFile)[^\n]*try\?'
    message: "IO 失败必须记日志或向上报错，不要 try? 吞掉"
    severity: error
```

针对本项目的**具体规则取舍理由**：

- `force_unwrapping` 必须开 `error`：`SMC.swift:43` 与 `:53` 的 `effectiveKey!` 目前靠"上方分支必然赋值"隐式保证；任何一次重排都会变成崩溃。改成 `guard let key = effectiveKey else { return 0 }` 后规则自然通过。
- `type_body_length` / `file_length` 对本项目最有用：`PowerChartView.swift`（915 行）把 `PowerChartView`、`ChartDraw`、`PlotRect`、`ScrollCatcherView`、`niceStep`、轴数学全塞在一个文件里。建议按 `Sources/MacBatteryCore/ChartMath.swift`（数学）+ `ChartDraw.swift`（绘制）拆开 —— 这同时解决 3.3 的可测性需求，一举两得。
- **不要开** `explicit_acl`（会逼着把 `internal` 写满）、`missing_docs`（中文注释已在关键处覆盖）、`trailing_whitespace` 之外的格式类规则（交给 swift-format）。
- swift-format：用默认配置 + `--in-place`，把它作为 `git pre-commit` 或 CI 的 `--lint` 步骤，不引入 `--strict`（避免一次性几百行 diff 淹没真正的改动）。
- 建议加一条**自定义架构规则**（比通用 lint 更值钱）：禁止 `Sources/MacBatteryCore/**` 出现 `import AppKit` / `import IOKit`，用 `custom_rules` 的 `regex: '^\s*import (AppKit|IOKit)'` + `severity: error`，路径限定只能靠 CI 脚本实现（SwiftLint 的 `included` 不支持按目录禁某规则）。这能保证"纯逻辑层"永远可测。

### 4.2 断言与日志策略：当前 `try?` / `catch {}` 清单与处理建议

本项目在异常路径上基本是静默的。建议引入 `os.Logger`（统一日志，`log show --predicate 'subsystem == "com.zioon.macbattery"'` 可事后取证），并按下面清单**逐点补齐**（按重要性排序）：

| 位置 | 现状 | 建议 |
|---|---|---|
| `PowerLogger.swift:177` `guard let h = try? FileHandle(forWritingTo: url)` | 静默 nil → 数据全丢 | `do/catch` + `logger.error("打开 power_log.csv 失败: \(error)")`，并在 UI 暴露持久化故障状态 |
| `PowerLogger.swift:152` `guard let h = fileHandle() else { return }` | 静默丢弃整批 | 记 `warning`，把 `batch` 保留在 `pending`（带上限）避免直接丢 |
| `PowerLogger.swift:175` `FileManager.default.createFile(...)` 返回值忽略 | 失败无痕 | 检查返回值，失败即记 `error` |
| `PowerLogger.swift:212` / `BatteryHealthLogger.swift:258` `else { break }` | 整段放弃且无痕 | 记 `error` + 改为容错解码（见 P1-6） |
| `PowerLogger.swift:134` / `BatteryHealthLogger.swift:180` `try? h.close()`、`:137` `try? removeItem` | 重置失败无痕 | 记 `error`；`removeItem` 失败时应让 `reset()` 向上报告"磁盘未清空" |
| `Battery.swift:156-158` `catch { return nil }`（`process.run()` 失败） | 退回兜底且无痕 | 记 `debug`（每 2s 一次，别用 info 刷屏），便于诊断"为什么充电状态总是靠兜底" |
| `Battery.swift:53-61` 句柄重建分支 | 无日志 | 记 `notice("AppleSmartBattery 句柄失效，重建")` —— 这是 P0-1 竞态的**唯一可观测信号**，装上它才能判断竞态是否真的在发生 |
| `Battery.swift:194-199` `readProperties` 失败 | 无日志 | 记 `notice`，用于统计"读失败率" |
| `SMC.swift:47-52` 连接重建 / `effectiveKey=nil` | 无日志 | 记 `notice`，并加"连续 N 次失败"计数 |
| `SMC.swift:43,53` `effectiveKey!` | 无断言 | 改为 `guard let`；若坚持保留，加 `assertionFailure` + `precondition` |
| `SystemPower.swift:49-53` helper JSON 解析失败 | 静默回退估算（**用户会以为估算值就是真值**） | 记 `debug`，并在 UI 上区分"实测 / helper / 估算"（现在的 UI 无法区分，这是可观测性问题） |
| `Updater.swift:273` `try? moveItem` | 静默失败 | `do/catch` + 记 `error` + 回落到 `Data(contentsOf:)` 写入 |
| `Updater.swift:197` `try? removeItem(at: destination)` | 静默 | 记 `debug`（覆盖旧 DMG 属正常） |
| `MacBatteryHelper/main.swift:46-48` `catch {}` | 静默 | 写 `stderr`（已被 `StandardErrPath` 收集到 `/tmp/macbattery-helper.log`，见 `install_helper.sh:45-46`）——**这条几乎零成本，收益最高** |
| `FloatingPanel.swift:61-64` `deinit` 里的 `Task` | 静默不执行 | 改为显式 `shutdown()`，并加 `logger.debug` 证明清理路径被执行 |
| `AppSettings.swift:121` `try? createDirectory`（Logger 中） | 静默 | 记 `error` |
| 全局 | 无崩溃收集、无 launch 埋点 | 至少在 `applicationDidFinishLaunching`（`main.swift:15-19`）记一条 `notice`，含版本号、`AppVersion.current`、是否读到 helper |

**断言策略**：只在"编程错误"上用断言（不变量被破坏），不要在"环境问题"上断言。具体建议：
- `SMC.swift` 的 `effectiveKey` 非空不变量 → `precondition`（debug/release 都检查，代价可忽略，每 0.5s 一次）；
- `PowerMonitor.performSampling` 中加 `dispatchPrecondition(condition: .onQueue(sampleQueue))` —— 这是**验证 P0-1 修复是否彻底的最廉价手段**，一旦有人在主线程调用立刻崩溃在开发期而非线上；
- `PowerLogger` / `BatteryHealthLogger` 的 `samples` 升序不变量 → 仅 debug `assert(samples.isSorted)`，防止时钟回拨导致的二分查找失效（`PowerChartView.swift:212-221` 依赖升序）。

**质量门禁建议（落到 CI）**：
1. `swift test`（纯逻辑层）+ `swiftlint --strict`（只对 `error` 级别失败）+ `swift-format lint`；
2. 禁止 PR 增加 `try?` 用于 IO（用上面 4.1 的 `custom_rules` 卡住增量，存量逐步清零）；
3. 版本一致性检查：`AppVersion.fallback`（`Updater.swift:11`）必须等于 `CHANGELOG.md` 最新版本号，用一个 5 行脚本在 CI 里断言；
4. `workflow_dispatch` 的产物版本号必须等于 `AppVersion.fallback`（见 P2-15），否则失败。

---

## 五、如果只修 3 件事

1. **P0-1：把采样线程模型拨回正轨（`PowerMonitor.swift:121` + 缓存加锁）**
   理由：这是唯一一条"会崩溃"的缺陷，且发生的时机（休眠唤醒 + 插拔）是**每个笔记本用户每天都会经历**的；同时它会让 CPU%/功率这类核心读数长期错误。修复成本极低（`scheduleSample` 改成入队 + 给 3 个静态缓存加锁），收益/成本比最高。**顺带加 `dispatchPrecondition` 把它钉死在 CI/开发期。**

2. **P0-2：`pmset` 子进程先读管道、加超时、离开主线程（`Battery.swift:144-174`）**
   理由：它同时是"启动卡顿"、"采样停摆"、"潜在死锁"三个症状的根因，而这三者正是本产品 CHANGELOG 里反复出现的主题（采样节拍、插拔感知延迟）。改动局部（一个函数），无需架构调整。

3. **P1-5 + P1-6 + P2-1：堵住历史数据的静默丢失（`PowerLogger.swift:152,177,212` + `:94`）**
   理由：历史曲线是用户唯一会"看第二眼"的功能，而当前"磁盘写不进去"和"读不回来"两种情况都是**无声失败**，用户只会认为"这软件坏了"。三处修复共用一次改造（`os.Logger` + 容错解码 + 回填 merge 对齐健康日志的既有实现），并且是 1.1.9 修复的**同一区域的补齐**，属于"把已修一半的 bug 收尾"。

> 次优先（第 4 件候选）：P1-3 位置预设被"自定义位置"覆盖 —— 用户可见度很高（选角不生效、菜单勾选消失），若主理人认为"功能正确性"优先级高于"数据完整性"，可与第 3 件互换。

---

## 六、无法验证 / 需实机确认

以下结论均为 **Windows 上的静态代码推断**，未经过编译、运行或真机验证，需在 macOS 上确认后才能作为修复依据：

| 编号 | 需确认的内容 | 确认方法 |
|---|---|---|
| 1 | `NSWindow.setFrameOrigin` 是否确实发出 `NSWindowDidMoveNotification`（决定 P1-3 是否真实存在） | 真机跑，在 `observeWindowMove` 回调里打日志；或直接选一次「位置 → 左下角」看菜单勾选是否消失 |
| 2 | `PowerMonitor` 的主线程采样路径与实际队列采样是否真的并发重叠（P0-1 的触发概率） | 在 `Sampler.sample` 首行打 `Thread.current` + `dispatchPrecondition`，观察是否命中主线程；连续做"休眠-唤醒-插拔"20 次统计 |
| 3 | `pmset -g batt` 在目标机型上的实际耗时（P0-2 的卡顿幅度） | `time pmset -g batt` 冷/热各 10 次 |
| 4 | 休眠唤醒后 `AppleSmartBattery` 句柄是否真的失效（P0-1 的触发前提） | 在 `Battery.swift:53` 分支打日志，观察 wake 后是否命中 |
| 5 | `FileHandle(forWritingTo:)` + `seekToEnd()` 在 APFS 上被 `SIGKILL` 后是否可能留下半行（影响 P1-6 的"部分行"边界） | 写入过程中 `kill -9`，检查 CSV 末行 |
| 6 | `.accessory` 策略下 `NSAlert.runModal()` 的焦点行为（P2-7） | 启动即触发更新提示，观察弹窗是否前置 |
| 7 | `NSScreen.main` 在多屏、且挂件在副屏时的实际取值（P2-8） | 双屏环境打印 `NSScreen.main?.frame` |
| 8 | `SizePreset.small`(0.8) 下 `margin = 20 - 6*0.8 = 15.2` 的视觉间距是否可接受（`FloatingPanel.swift:96`） | 三种尺寸截图对比 |
| 9 | 两种 `UserDefaults` domain 是否真的不共享（P2-13） | `defaults read` 对比 `swift run` 与 `.app` |
| 10 | ad-hoc 签名产物在 macOS 12/13/14/15 上的 Gatekeeper 表现（P2-18） | 干净机器（无开发者证书）下载后双击 |
| 11 | 24h 挂机后的内存/CPU 曲线（P2-3、P2-14、P1-4） | `leaks` / `vmmap` 采样，或 Instruments |
| 12 | `PowerChartView.swift` 915 行的绘制在 24h 窗口下的掉帧情况（P2-14） | Instruments → Animation Hitches |
| 13 | 所有行号引用 | 本报告基于分支 `workbuddy/main-247e6f68` 的当前工作区快照；若上游已提交修改行号会漂移，**引用不确定性最高的是 `PowerChartView.swift`（915 行）与 `BatteryHealthChartView.swift`（704 行）**，改代码时请以函数名 + 就近行号复核 |
| 14 | `Package.swift` 增加 `MacBatteryCore` target 后是否会影响 universal（`--arch arm64 --arch x86_64`）构建 | 在 macos-14 跑一次完整 CI |

---

## 附录 A：已确认无缺陷的高风险区域（供架构师参考，避免重复排查）

- CSV `seekToEnd` + 表头去重（1.1.7 修复）：`PowerLogger.swift:180,183-186` 与 `BatteryHealthLogger.swift:225,228-231` —— 正确，未回归。
- 跨块行拼接 `leftover` 算法：`PowerLogger.swift:213-221` —— 正确。
- 充电功率计算 `ampereAbs * volt / 1e6` 与"严格跟随 `isCharging`"：`Battery.swift:85-90` —— 正确（1.1.1 / 1.1.8 修复有效）。
- `finishing charge` 计入充电、`charged` 不计：`Battery.swift:167-169` —— 正确（1.1.10 修复有效）。
- `VersionCompare` 数字段比较：`Updater.swift:64-79` —— 正确，含 `v` 前缀与非数字后缀。
- `PowerLogStore` / `BatteryHealthLogStore` 的内部状态只在各自 ioQueue 上访问：设计正确，`nonisolated let store` + `DispatchQueue.async` 的写法是这里唯一正确的并发处理。
- `PowerLogger.reset()` 的代际校验：`PowerLogger.swift:93` —— 正确覆盖"重置前已发出的回填"。
- 绝对时间锚定分桶 + 台阶式右轴：`PowerChartView.swift:589-605, 348-370` —— 算法自洽，未发现数学错误（但需实机验证视觉稳定性）。
- `niceViewport` 的退化值处理：`PowerChartView.swift:320-326` —— `hi == lo` 时以 1 为跨度居中，未发现 NaN/负跨度路径。
- helper `atomically: true` + `chmod 0644`：`MacBatteryHelper/main.swift:45,50` —— 原子且意外缓解了符号链接攻击面。
- `install_helper.sh` 的 launchd 配置：`Scripts/install_helper.sh:30-56` —— 结构正确，`KeepAlive` 会导致"主动退出也被重启"，属预期行为需在文档说明。

---

## 附录 B：与架构评审（software-architect）的交叉核对结论

> 本节为报告交付后与 `software-architect` 通过 SendMessage 交叉核对的结果，用于给主理人汇编时提供**可信度权重**。两条线独立完成、互不通气。

| 项 | 我方（QA）编号 | 架构方编号 | 核对结论 |
|---|---|---|---|
| 采样线程模型被打破（主线程就地采样） | **P0-1** | 2.1 / 2.4 | **两人独立命中同一处**（`PowerMonitor.swift:121-124`）。这是本次评审可信度最强的信号 |
| `pmset` 子进程阻塞 | **P0-2** | 3.1 | 结论一致，**措辞需精确化**（见下） |
| 第二个主线程入口 `BatteryHealthLogger.start()` | P0-1 的子项 | 我方补充后被架构方**采纳**（其初稿遗漏） | 架构方已回补报告 2.1 并致谢；其原稿只从 `PowerMonitor` 持有者角度追链，漏了从**共享状态反查所有访问者** |
| 位置双状态源（选角被改写成自定义） | **P1-3** | 1.4（架构方判定为本次交叉核对**最高价值发现**） | 同一问题，触发链双方核实一致。**第二轮核对修正两点**：① 投递确认为**异步**（`queue: .main`），双方均不会重入；② 我方原"菜单勾选全丢"的表述不准确，真实后果是"与真实状态脱节、下次重建才暴露"，持久影响是**角落锚定丢失**（详见下方第二条） |
| `deinit` 中 `Task { [weak self] }` 清理失效 | **P1-2** | 1.5 | 同一问题。架构方定为 P2（理由：`AppDelegate` 强持有 `windowController`，实际泄漏概率低）——**建议采纳架构方的 P2**，我方原 P1 只因"最终 flush 丢失"而抬级，实际影响面更小 |
| `cachedService` 泄漏 / `generation` 重置竞态 / 跨块行拼接逻辑 | 附录 A 判非缺陷 | 事前亦未列为待修 | **三方一致**：均判定为非缺陷，不应进入待修清单 |

**关于 P0-2 的措辞（重要，避免给作者错误印象）**
架构方的精确化是对的，且与我报告 P0-2「影响」段的表述一致：

- **`pipe` 死锁是结构性隐患、当前触发概率极低** —— `pmset -g batt` 输出仅百字节级，远小于 64KB 管道缓冲。**不得表述为"已发生的故障"**。
- **主线程阻塞是已发生的事实** —— `waitUntilExit()` 阻塞的是调用线程，而当前调用线程就是主线程（启动首拍主线程采样路径）。
- 两者修法同一（采样移出主线程 + pmset 改非阻塞 `terminationHandler`），可一次消除。**给作者的问题描述请用「主线程阻塞（已发生）+ 管道死锁（结构隐患，低概率）」这一措辞。**

**第二轮核对（P1-3 / 架构 1.4）—— 我方保留意见已收敛，并接受两处修正**

架构方完成了 1.4 的投递时序推演，我逐条复核后**接受**，并据此修正本报告 P1-3 的"影响"与"修复建议"（正文已更新）：

- **已解决一半**：投递语义**确定为异步**（块式观察者注册到 `queue: .main` → 回调被投递到主队列，不在 `post` 的栈内内联）。我方另补充一条独立证据并已核实：`rememberDrag`（`AppSettings.swift:76-84`）**不调用 `commit()`/`onChange()`**，故即便假设同步投递也不会重入 `applySettings()`。**"同步投递导致重入"这一更坏形态被排除。**
- **剩余唯一保留点已收窄为一句**：程序化 `NSWindow.setFrameOrigin` **是否会 post** `NSWindowDidMoveNotification`。Apple 文档未作契约保证，双方均无法静态断定 → 仍需真机确认（见第六节第 1 项）。确认前表述为**"高度可疑（机制清晰、证据为静态推断）"，不得表述为"已复现"**。
- **我方两处修正（架构方指出，我接受）**：
  1. 原"菜单勾选立刻全丢"**不准确**：`chooseCorner` 在 `setFrameOrigin()` 后**同步**调 `rebuildMenuCheckmarks()`（`FloatingPanel.swift:246`），此刻 `hasCustom` 仍为 `false`，勾选当场是对的，只是**已与真实状态脱节**，下次重建才暴露。真实持久影响应写为：**①设置面板长期误显"已在自定义位置"；②角落锚定丢失**（改尺寸/换分辨率后不再贴角、可能落到屏外）。
  2. 我方原"抑制标志 + `DispatchQueue.main.async` 清零"的时序论证**不严谨**：观察者块与清零块都排在主队列，先后取决于入队时刻，无保证。**接受将值比较列为首选修法。**
- **我方对修法的两点 QA 反哺**（已写入 P1-3 正文）：
  1. 值比较需加**容差**（≤ 0.5pt），防 backing scale / 舍入造成 1 像素级误判；
  2. 需在注释中写明一个**已知可接受边界**：用户若把窗口拖回并恰好停在该程序化原点，该次 `didMove` 会被吞掉（概率极低、自恢复）。
  3. 提醒：`PanelPosition` 枚举消除的是**状态散落**，**不能替代来源判据**（`didMove` 无来源信息），故枚举须与值比较配套，不能单独作为修法。

> 结论：P1-3 的**优先级与定性不变**（真机确认"会 post" → P1 优先；确认"不会 post" → 降 P2 仅保留状态建模价值），但**修法已从"抑制标志"升级为"值比较 + 枚举单一真相源"**，且值比较可**先落地、无副作用**。见正文 P1-3。

**第三轮核对（我方自审 + 架构方 1.4 收尾）**

1. **架构方接受我的清空语义修正**，并给出配套改法：把 `applySettings()` 的"两步动窗口"（`:82` `setContentSize` + `:87`/`:117` `setFrameOrigin`）合并为**单次 `setFrame`**，从源头消除"一次程序化移动可能发多条 `didMove`"的不确定性，使"第一次 `didMove` 无条件清空"的语义**安全**。我复核 `FloatingPanel.swift:70-88` **确认现状确为两步**，**接受该配套改法**。我方补充两点：① 严格说 `setContentSize` 在原点不变时更可能发 `didResize` 而非 `didMove`，故"两条 `didMove`"当前未必发生——但合并为单次 `setFrame` 仍**更可取**，因为它是**确定性**的；② 合并后还额外消除"旧原点 + 新尺寸"的中间态（`setContentSize` 在前、`setFrameOrigin` 在后），对角落锚定的挂件可避免一次几何跳变。**两项均无需争论，接受。**
2. **我方自审修正了一处自己的不准确**：P0-1 的触发路径，我原列为"启动 / 电源事件 / `refreshOnce`"三条。grep 核实 `refreshOnce()`（`PowerMonitor.swift:103`）**全仓无调用点**（死代码），故该路径**当前不可达**；已把 P0-1 的可达入口修正为 **`start()`（`:89`）+ `powerSourceChanged()`（`:177`）两条**，并把 `refreshOnce` 改注为"埋着的引信"（见 P2-20）。**该修正不改变 P0-1 的定性与优先级**（两条可达路径已足以在启动与每次插拔时触发），但提升了缺陷描述的准确性。
3. **我方新增两条 P2**（源于同一段代码的复核，非架构方提出）：**P2-19** 设置变更时 `NSHostingView` 整树重建 + 两步动窗口（TDP 滑块拖动是最高频触发路径，且 TDP 不参与 HUD 布局）；**P2-20** `saveCustomPosition` / `refreshOnce` 两处死代码恰是各自的"危险版本"，建议删除或注释警示。
4. **架构方判定 1.4 已具备交 Engineer 实施的条件**，我作为 QA 认同"**修法可先落地、验证需两次真机测量**"这一分法，并补充验收要求：P1-3 的定位几何应抽为纯函数（如 `originFor(corner:visibleFrame:size:margin:)`）并纳入 `swift test`（见本报告 §3.2 第 1 层），否则修复本身无回归保护。

> 三轮核对的一致结论：**两份报告无冲突**；4 项一致 + 2 项我方修正 + 2 项架构方采纳 + 2 项我方新增 P2 + 1 项我方自审纠错。P0-1 仍是全项目最高置信度缺陷（双人独立命中，且入口已核实可达）。

---

*报告结束。所有行号基于 `workbuddy/main-247e6f68` 工作区快照；未编译、未运行，结论为静态推断。附录 B 为交付后与架构评审交叉核对的结果补充。*
