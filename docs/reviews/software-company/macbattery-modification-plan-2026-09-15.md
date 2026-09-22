# MacBattery 项目接管评审 · 统一修改方案

- **主理人**：齐活林（交付总监）· software-macbattery-review 团队
- **评审对象**：MacBattery @ `workbuddy/main-247e6f68`，最新 tag `v1.1.10`，约 4500 行 Swift/C
- **参与成员**：高见远（架构师）· 系统架构评审；严过关（QA 工程师）· 质量与测试评审
- **评审方式**：**只读静态代码阅读**。环境为 Windows，**未执行 `swift build` / `swift test` / 任何运行时验证**，所有涉及运行期行为的结论均为静态推断。
- **源码改动**：**零**。本方案与两份成员报告均为新增文档。

---

## 一、一页结论

MacBattery 是一个**工程质量明显高于同规模个人项目**的成品，**不需要推倒重来**。但它当前的健康度是"靠注释维持"而非"靠机制保证"——而这个约定**已经被生产代码打破了**。

两位成员从不同角度独立工作，**同时命中同一个 P0**：

> `PowerMonitor.scheduleSample()`（`PowerMonitor.swift:121-124`）在 `@MainActor` 上**同步调用** `performSampling()`，导致主线程执行 `pmset -g batt` 子进程并在主线程并发访问一批"声明为无锁"的静态缓存。

我独立复核后确认属实，并且发现它**有两个独立入口**（见 3.1），比架构师最初判断的还严重。

**修复成本**：核心修复约 2 行，配套加固约 30 行。**这是全项目风险最高、成本最低的一处。**

**第二个必须立刻处理的是用户数据的静默丢失面**：磁盘写入失败、UTF-8 解码失败都会让整段历史无声消失，而项目里没有日志、没有断言、没有任何提示——出事之后用户和开发者都无从定位。

**不要修的东西**（评审明确建议保留）：CSV 分块倒读、像素分桶平均 + 绝对时间锚定、台阶式右轴、后台 `DispatchSourceTimer` 心跳、`seekToEnd` 追加写、`finish charge` 判定。这些是经过多次迭代打磨、解决了真实痛点后收敛的设计。

---

## 二、交叉印证与分歧裁定

### 2.1 两位成员独立命中的同一处（可信度最高）

| 结论 | 架构师编号 | QA 编号 | 裁定 |
|---|---|---|---|
| 主线程打破"仅后台串行队列"约定，并发访问硬件静态缓存 | 2.1（P0） | P0-1 | **P0，必须立刻修** |
| `pmset` 子进程同步阻塞、无超时 | 3.1（P1） | P0-2 | **P0，与上条同批修** |
| SMC 候选键三处不一致（含 README） | 5.1（P1） | P2-18 | **P1**（成本极低、确定性收益） |
| 版本号双处维护 + CI 手动触发版本号错 | 7.1（P1） | P2-15 | **P1** |
| `AppVersion` / `VersionCompare` 位置不当 | 1.3（P2） | 3.2（可测性障碍） | **P2**，并入测试改造一并处理 |

### 2.2 分歧裁定

| 事项 | 架构师 | QA | 主理人裁定 |
|---|---|---|---|
| `PowerLogger` 回填覆盖（`PowerLogger.swift:94`） | P1 | P2 | **P1**。理由：`BatteryHealthLogger` 在 1.1.9 已修为 `merge(history:new:)`，功率日志漏修——属"同一个 bug 只修了一半"，且修复就是把已有实现抽出来共用，成本极低。这类"修一半"模式正是历史回归的温床。 |
| `pmset` 是否可用纯 IOPS 替代 | 建议分两步，第二步需实机验证 | 建议直接替代 | **采纳架构师意见**。CHANGELOG 显示 1.0.9→1.1.0→1.1.7 在三条判定路径间反复摇摆，说明作者曾实测到 IOPS 在某些机型上滞后/缺失。**未经实机复现不得替换**。 |
| `pmset` 管道读取顺序倒置的定性 | 措辞应精确化：**主线程阻塞（已发生）** + 管道死锁（低概率结构隐患） | 表述为"结构性死锁隐患" | **采纳架构师**。`pmset -g batt` 输出仅百字节级，远小于 64KB 管道缓冲，**当前触发概率极低**；同一段代码真正已发生的问题是 `waitUntilExit()` 阻塞调用线程。**不得把隐患表述为已发生故障**（详见 3.1 P0-B） |
| `FloatingPanel` 的 `deinit` 清理永不执行 | P2（`AppDelegate` 强持有，实际泄漏概率低） | P1（timer 泄漏、最后一段样本丢失） | **裁定为 P2**。理由：`FloatingPanelController` 由 `AppDelegate.windowController` 强持有至进程退出，实际不会被释放，因此"泄漏"实际不发生；`PowerLogger.stop()` 的最终 flush 不执行只损失退出瞬间 ≤1s 样本，与 Ctrl+C 退出（P2-17）同类。**但修复仍值得做**——它是"意图明确却静默失效"的死代码，一旦将来控制器变为可释放就会立即变成真缺陷。 |

### 2.2.1 成员交叉核对结果（修订后）

架构师在收到 QA 的交叉核对后提交了修订版报告（同一路径已覆盖），双方现就以下事项**完全一致**：

- P0 指向同一处代码（`PowerMonitor.swift:121-124`），且均确认**存在第二个主线程硬件入口**（`BatteryHealthLogger`）；
- **§1.4 / QA P1-3**（面板位置双状态源）——QA 先发现，架构师核实后采纳并补全了触发链的精确描述；
- **§1.5 / QA P1-2**（`deinit` 清理）——QA 先发现，架构师核实后采纳，但两人对**严重度定性不同**，已由主理人裁定为 P2（见上表）；
- 架构师核实确认 QA 推翻的 3 条误判（`cachedService` 有界、`generation` 代际校验正确、跨块行拼接正确）**同样成立**。

**这意味着：本次评审的 P0 结论由两人互不通气、独立复核得出，是目前可信度最强的信号。**

**架构师的第二轮自我修正（值得记录，说明成员的结论是可信的而非堆砌的）**：架构师在复读后**主动撤回**了自己在 §1.4 中的一处过度断言，并修正了修法排序：

1. **撤回**："选角落后菜单勾选立刻全丢" —— 不准确。因通知投递延后，`chooseCorner` 同步重建菜单时 `hasCustom` 仍为 `false`，**勾选当场是对的**，只是状态已脱节，需下一次菜单动作触发重建才显形。
2. **推演出一条无需真机验证的确定结论**：观察者以 `queue: .main` 注册，块被投递到主队列而非在 post 栈内内联，故**投递必为异步、`applySettings()` 栈早已返回**；又因 `rememberDrag` 不调用 `commit()`/`onChange`，**当前代码不会重入**。
3. **修正修法排序**：首选从"抑制标志"改为**值比较**（`lastProgrammaticOrigin`）—— 免疫同步/异步投递，且"AppKit 会 post / 不会 post"两种情形下**均无副作用**，因此**可先落地**，不必等真机确认；`PanelPosition` 枚举降为结构性并列首选（消除状态散落，但**不能**单独判别移动来源）；抑制标志降为次选。

### 2.2.2 第二轮：两人再次独立收敛于同一修正

值得记录的是，**QA 在第二轮交叉核对中独立得出了与架构师完全相同的修正**（QA 原稿的"位置菜单四项全部无勾选"同样被其自己撤回），并额外指出一个关键点：

> **不要修"勾选丢失"的表象，而放过真正的"角落锚定丢失"。**

主理人已据此把 U-04 的后果**以"角落锚定丢失"为主线**（见 3.2）。

**两轮独立收敛，说明这两份报告不是互相附和，而是各自推演后在同一结论上会合。** 这也是主理人敢于把它们汇编为一份交付的依据。

**这正是"信任但验证"应有的样子：成员主动收窄自己的断言范围，而不是把不确定的东西讲成确定的。**

### 2.3 被推翻的怀疑（重要：避免误导排期）

我上一轮通读时提出的 6 条怀疑中，QA 逐条复核后**推翻了 3 条**，我认可：

| 原怀疑 | 复核结论 |
|---|---|
| `IOServiceGetMatchingService` 的 `cachedService` 从不释放 → 泄漏 | **非缺陷**。进程生命周期内最多存在 1 个句柄（`rebuildService` 会先释放）。真正的问题是它的**跨线程访问**，不是句柄数量。 |
| `PowerLogger.generation` 未能覆盖重置竞态 | **基本正确**。代际校验有效；`clearDisk` 与 `write` 由同一 ioQueue 串行保证，FIFO 下"先写后删"净效果正确。 |
| `readRecentHistory` 的"非首块丢弃首行"逻辑有误 | **逻辑正确**。标准且正确的跨块行拼接。真正的问题是整块 UTF-8 解码失败（见 3.1 P1-D）。 |

另有 4 处经复核确认**已正确修复、未回归**：CSV `seekToEnd` + 表头去重（1.1.7）、充电功率符号与"严格跟随 `isCharging`"（1.1.1/1.1.8）、`finishing charge` 判定（1.1.10）、`VersionCompare` 数字段比较。

**结论：这 3 条不建议列入待修项。** 但它们揭示了一个更值得注意的事实——**项目里"看起来有问题"的地方比"真的有问题"的地方多**，这本身就是缺少测试与可观测性的症状。

---

## 三、统一优先级清单

### 3.1 P0 — 立刻修（正确性风险 + 成本极低）

#### U-01（原 P0-A）主线程打破硬件访问的并发约定

**位置**：`PowerMonitor.swift:121-124`（`scheduleSample()`）；**可达调用点 `:89`（`start()`，启动首拍）+ `:177`（`powerSourceChanged()`，每次插拔电源）**。

> ⚠️ **入口账目已核实**（QA 主动自我纠错 + 主理人用 grep 复核）：`:104` 的 `refreshOnce()` **在全仓没有任何调用点，是死代码**，因此它列为**第三条入口是不成立的**。`PowerMonitor` 侧的可达入口是**两条**，不是三条。
> **P0 的定性与优先级完全不受影响**——`:89` 与 `:177` 已足以在**启动**与**每次插拔电源**时触发，危险场景仍在。
> 但这条死代码是**埋着的引信**（见 3.3 的 U-13）：若后人"顺手"把它接上，就是一个新的主线程采样入口。

**问题**：`scheduleSample()` 是 `@MainActor` 类上的普通方法，内部**同步调用** `nonisolated performSampling()`——即在**当前线程（主线程）**上执行完整采样。

**我复核后新增的关键事实：它有第二个独立入口，且是周期性的。**

`BatteryHealthLogger.start()`（`BatteryHealthLogger.swift:51-60`）同样是 `@MainActor` 类上的普通方法，其中：
- `:59` `sample(force: true)` → `:87` `BatteryReader.health()` → `Battery.swift` 的 IOKit 注册表读取，**启动时在主线程执行**；
- `:54-56` 的 60s `Timer` 回调内 `Task { @MainActor in self?.sample() }` → **每 60 秒在主线程做一次 IOKit 读取**；
- `:68-69` `recordNow()`（打开健康窗口时调用）同理。

所以这不是"启动瞬间"的一次性问题，而是**每 60 秒周期性发生的主线程硬件访问**，与 0.5s 采样队列的 tick 长期重叠。

**入口总账（已逐条核实可达性）**：主线程硬件访问共 **5 条可达入口** —— `PowerMonitor` 侧 2 条（`start()` 启动首拍、`powerSourceChanged()` 每次插拔）+ `BatteryHealthLogger` 侧 3 条（启动强制采样、60s 周期采样、`recordNow()` 打开健康窗口）。其中 **60s 周期那条是长期反复发生的**，也是与采样队列重叠概率最高的一条。

> **不要把 `refreshOnce()` 计入** —— 它是死代码（见上）。主理人已用 grep 独立复核。

**影响**：
- `BatteryReader.cachedService`（`Battery.swift:10`）、`SMCReader.conn` / `effectiveKey`（`SMC.swift:21,23`）、`SystemPower.lastCpuTicks`（`:58`）全部无锁。
- 最坏路径：休眠唤醒 → 句柄失效 → `chargingStatus()` 首读三属性全 0 → 命中 `Battery.swift:53` → `rebuildService()` → `IOObjectRelease(cachedService)`，而此处若与另一线程的读取重叠 → **use-after-free**。
- 用户可见症状：数字突然变 `0` / `--`，或应用直接闪退。**概率性触发，极难复现，事后无法从日志定位。**

**修复方案（分三步，按风险从低到高）**：

1. **先加锁（消除正确性风险，无副作用）**——给 `BatteryReader` / `SMCReader` / `SystemPower` 的静态可变缓存各加一把 `NSLock`（注意目标 macOS 12，`OSAllocatedUnfairLock` 需 macOS 13+，`Mutex` 需 Swift 5.9+，因此用 `NSLock` 或 `os_unfair_lock`）。这是**唯一能同时覆盖所有当前与未来入口**的做法，不改变任何调用结构，约 20 行。
2. **再改投递（消除主线程阻塞）**——`scheduleSample()` 改为只入队，不再就地采样：
   ```swift
   private func scheduleSample() {
       tdpBox.value = settings.tdpWatts
       sampleQueue.async { [weak self] in self?.performSampling() }
   }
   ```
   同时把 `BatteryHealthLogger` 的硬件读取（`BatteryReader.health()` / `level()`）移到后台，只把"结果应用"留在主线程。**注意**：这会改变启动时"新点先写入内存"的时序，1.1.9 的 merge 修复仍需重新验证顺序（merge 本身对两种顺序都成立）。
3. **加护栏（防回归）**——在 `Sampler.sample()` 入口加 `dispatchPrecondition(condition: .notOnQueue(.main))`，违约立刻在开发期崩溃而非线上静默竞态。**必须在第 2 步完成后才能加，否则会误伤 `BatteryHealthLogger`。**

**顺带解决**：`TDPBox.value`（`PowerMonitor.swift:183-189`）的裸 `var` 跨线程读写。随第 1 步加锁一并解决；若采用值传递（在 `scheduleSample()` 内捕获 `tdp` 快照再入队）则可直接删除 `TDPBox`，彻底消除共享可变状态。同理处理 `BatteryReader.lastEventRefTime`（`:14`）。

**优先级理由**：这是唯一一条"会崩溃"的缺陷，触发时机（休眠唤醒 + 插拔电源）是每个笔记本用户每天都会经历的。

---

#### U-02（原 P0-B）`pmset` 子进程：主线程阻塞 + 读取顺序倒置 + 无超时

**位置**：`Battery.swift:144-174`，关键行 `:159` `process.waitUntilExit()`、`:161` `readToEnd()`

**问题（QA 独立发现、架构师复核后精确化定性）**：

必须区分两个层次，**不得混为一谈**：

- **已发生**：`waitUntilExit()` 在**调用线程**上同步阻塞。在当前代码下调用线程就是主线程（见 P0-A），因此**这是正在发生的性能缺陷**，而非隐患。
- **低概率结构隐患**：`waitUntilExit()` 位于 `readToEnd()` **之前**。若子进程输出超过管道缓冲区（macOS 默认约 64KB），子进程写满阻塞、父进程等它退出，双方互等。**但 `pmset -g batt` 输出仅百字节级，当前触发概率极低**，且 `Pipe` 未设上限、无超时——没有任何机制阻止它将来触发。

**影响**：
- 启动首拍在主线程 fork/exec `pmset`（冷启动通常几十到几百毫秒）→ 浮窗首帧延迟；
- 采样队列被阻塞 → 采样节拍拉长 → 历史曲线空洞、插拔感知变慢（**这正是 1.0.9 已经修过一次的问题类型的回归路径**）；
- 子进程异常挂起时采样线程永久卡死，且无日志。

**修复方案**：
1. **先读管道再等退出**：`let out = pipe.fileHandleForReading.readDataToEndOfFile()` 放在 `waitUntilExit()` 之前（或改用 `terminationHandler` + 异步读）；
2. **加超时**：`DispatchWorkItem` + `process.terminate()`（建议 1.5s）；
3. **降低频率**：`pmsetCache` 缓存从 2s 提到 5s（`Battery.swift:146`），进程拉起次数从 ~30 次/分钟降到 ~12 次/分钟。**这一点在产品逻辑上有额外意义：这是一款电池工具，却为了读电池状态而持续 fork 进程消耗它监测的电池。**
4. **离开主线程**：依赖 P0-A 第 2 步。

**暂不做**（需实机验证）：用纯 IOPS API 完全替代 `pmset`。

---

### 3.2 P1 — 应当做（维护成本已可感知 / 用户可见）

> **编号说明**：为确保下游读者不面对两套成员编号，本节起采用**主理人统一编号 `U-xx`**；`来源编号` 列给出与两份成员报告的映射。P0 两项对应 **U-01 / U-02**（见 3.1），P2 项自 **U-11** 起（见 3.3）。

| 统一编号 | 主题 | 位置 | 说明 | 来源编号 |
|---|---|---|---|---|
| **U-03** | **历史数据静默丢失**（三处一次性改造） | `PowerLogger.swift:152,177,212` + `:94` | `fileHandle()` 打开失败被 `try?` 吞掉并 `return nil`，而 `batch` 已被 `flushPending()` 从 `pending` 移除 → **永久丢失且上层不知情**；`String(data:encoding:.utf8)` 整块解码失败直接 `break` → 整段历史读不回来。修复：引入 `os.Logger` 记录失败；失败时把 batch 回填 `pending`；解码改用 `String(decoding:as:UTF8.self)` 容错或按 `\n` 做字节级切分；回填改为 merge 对齐健康日志 | QA P1-5 / P1-6 / P2-1（架构师 2.3） |
| **U-04** | **位置预设被"自定义位置"静默覆盖** ⚠️ | `FloatingPanel.swift:90-131,120-131` + `AppSettings.swift:76-84` | 触发链：菜单选四角 → `chooseCorner()` 置 `hasCustom=false` → `commit()` → `applySettings()` → `positionPanel()` → `setFrameOrigin()` → AppKit 发出 `didMove` → `rememberDrag()` 把 `hasCustom` 写回 `true`。<br>**已可确定、无需真机验证的部分**：观察者以 `queue: .main` 注册（`:121-125`），块被投递到主队列而非在 post 栈内内联，故**投递必为异步、`applySettings()` 栈早已返回**；且 `rememberDrag` **不调用** `commit()`/`onChange`，**当前代码不会重入**。<br>**待真机确认的部分**：AppKit 是否对**程序化** `setFrameOrigin` 发出该通知——Apple 文档**无契约保证**，故"影响"只能表述为**高度可疑（机制清晰、证据为静态推断）**，**不得表述为"已复现"**。若确认真机"会 post"→ 升为 P1 优先；若"不会 post"→ 降 P2（仅保留状态建模价值）。<br>**可感知后果（三条）——⚠️ 请以第 ② 条为主线，否则会去修表象而放过根因**：<br>② **（主后果）角落锚定丢失** —— 此后 `chooseSize()` 改尺寸或换分辨率 / 显示器时，窗口**不再重新贴角**，停在旧坐标 → 间距漂移、极端情况落到屏外。**这是用户可感知的主要后果，比"勾选丢了"严重得多。**<br>① 设置面板长期误显"已在自定义位置"（`SettingsView.swift:24-28`）。<br>③ 菜单四项勾选在**下一次重建**（任一菜单操作 / 重启）后才变空。<br>**修正一处早前的过度断言**：先前"选角落后菜单勾选立刻全丢"**不准确**——因投递延后，`chooseCorner` 同步重建菜单时 `hasCustom` 仍为 false，勾选**当场是对的**，只是状态已脱节，需**下一次菜单动作触发重建**才会显形。<br>**修法排序**（两位成员各自提出、又各自撤回，最终收敛）：<br>**① 值比较（首选，且可立即落地）** —— 记录 `lastProgrammaticOrigin` 并与当前 origin 比对，需配 **≤0.5pt 容差**，且**第一次 `didMove` 无条件清空**。免疫同步/异步投递，且"AppKit 会 post / 不会 post"**两种情形下均无副作用**，因此**不必等真机确认**。<br>**② 配套修法（强烈建议与 ① 同批做）** —— 把 `applySettings()` 中的 `setContentSize`（`:82`）与 `setFrameOrigin`（`:117`）两步合并为**单次 `setFrame`**。三点必须说清：<br>&nbsp;&nbsp;• **收益表述须精确**：是"把通知条数从**不确定**变为**确定 1 条**"，**不可**写成"当前会发两条 `didMove`"——`setContentSize` 在原点不变时更可能发 `didResize`，该说法**无数据支持**。<br>&nbsp;&nbsp;• **★ 一条不依赖真机数据的确定收益**：现状两步动窗口存在"**尺寸已变、原点未随**"的中间态，角落锚定的挂件会**瞬间偏离角落**；合并后该中间态消失。**这是本条最扎实的依据，不需要任何真机数据支撑。**<br>&nbsp;&nbsp;• 同时降低 ① 对时序的敏感度。<br>**③ `PanelPosition` 枚举（结构性并列首选）** —— 消除状态散落，但**不能单独判别移动来源**，须配来源判据使用。<br>**④ 抑制标志（降为次选）** —— QA 原方案"设标志 → `setFrameOrigin` → `DispatchQueue.main.async` 清标志"被架构师指出**时序无保证**（观察者块与清零块都排主队列，先后取决于入队时刻），QA 复核后**已收回**。<br>**⑤ 收敛进 `PanelLayout`** —— 与 P2 的 `FloatingPanel` 拆分合并处理。**前置条件**：`observeWindowMove` 在 `:48` 注册、晚于 `:46` 首次 `applySettings()`，故启动时不受影响，须经一次菜单选角才触发 | QA P1-3 ＝ 架构师 1.4 |
| **U-05** | **SMC 候选键三处不同源** | `SMC.swift:12-18`、`MacBatteryHelper/main.swift:31`、`README.md:90` | 主程序与 helper 逐字重复，README 已错（写 `EDR0`，实为 `PSYS`）。修复：提升为 `SMCBridge` target 中的唯一常量（两个 Swift target 共同依赖），并修 README | 架构师 5.1 / QA P2-18 |
| **U-06** | **版本号双处维护 + CI 手动触发版本号错** | `Updater.swift:11`、`build-dmg.yml:48-53,8,83-88` | CI 不改源码只改产物 `Info.plist`，`fallback` 必须人工同步；`workflow_dispatch` 时 `GITHUB_REF_NAME` 是分支名，tag 覆盖分支不成立 → 产物版本号停在硬编码 `1.0.0`。后果：手动构建的包若被安装，应用内更新会**永远认为已是最新**。修复：CI 加 `version` 输入并覆盖 `Info.plist`；加"`fallback` 与 tag 一致性"校验步骤 | 架构师 7.1 / QA P2-15 |
| **U-07** | **图表公共基础设施抽取** | `PowerChartView.swift`(915) + `BatteryHealthChartView.swift`(704) | 逐项对照确认已复制粘贴：`PlotRect`/`HealthPlot`、拖拽平移、滚轮缩放、时间窗钳制（阈值 12s/20s 完全相同）、`niceTimeStep`、`xFormatter`、`nearestSample`、`drawHover`（像素偏移 10/26/15 相同）、折线描边（线宽 1.6/opacity 0.9 相同）。**且 `ScrollWheelCatcher` 定义在 `PowerChartView.swift` 却被健康图引用，形成隐式文件依赖**。这是本项目改动最频繁的区域（CHANGELOG 1.0.9→1.1.10 有 8 条涉及图表），已出现分叉 | 架构师 4.1 |
| **U-08** | **root helper 缺少 autoreleasepool** | `MacBatteryHelper/main.swift:18-22` | 顶层 `while true` 每轮无 `autoreleasepool`，`writePower` 经 Foundation 产生的自动释放对象使堆单调增长。该进程 `KeepAlive=true` 几乎不重启 → **一个长期占用 root 资源、内存持续上涨的守护进程**。修复：循环体内包 `autoreleasepool { }` | QA P1-4 |
| **U-09** | **可测试性改造** | `Package.swift:9-25` | 无 test target、无 `Tests/`、无 lint、CI 无 test job → 回归防线 **100% 依赖人工点击**。最小方案：新增 `MacBatteryCore` library target（4 个纯逻辑文件搬迁）+ `MacBatteryCoreTests` test target + CI 加 test job（`needs: test`） | 架构师 6.1/7.2 + QA 第三节 |
| **U-10** | **估算值未在 UI 上标注** | `PowerHUDView.swift:167-171`、`SystemPower.swift:17-20` | Apple Silicon 上 SMC 与 helper **都读不到**，整机功率 100% 是 `tdp*(0.05+0.95*u)+(7+3*u)` 的估算值，默认 tdp=45。而 UI 无任何"这是估算"的区分——**用户会把估算当实测**。修复：估算来源时数字后加 `~` 或灰色"估"字；设置面板说明"安装 helper 可读实测" | 架构师 8.1 路径 A |

### 3.2.1 U-04 的"完成定义"（QA 提出的验收底线，主理人已裁定采纳）

QA 提出一条**必须写进给工程师的完成定义**，否则这次修复没有回归保护：

> **U-04 修完后，四角定位几何必须抽成纯函数 `originFor(corner:visibleFrame:size:margin:)`，并纳入 `swift test`。**

**主理人裁定：采纳**，并补充两点校准，以免把它的作用说过头：

1. **这条把 U-04 与 U-09 强绑定** —— U-09（可测试性改造）不再只是"工程化收尾"，而是 **U-04 的验收前置**。
2. **但要诚实说明这个测试能证明什么、不能证明什么**：`originFor(...)` 覆盖的是**几何计算**（也正是 U-12 的单次 `setFrame` 合并、以及改尺寸/换分辨率那条路径会碰到的部分）；它**并不能直接覆盖"值比较"那几行抑制逻辑**。要覆盖后者，需要把窗口移动观察者整体抽象出来，**超出本次范围**。因此这条要求提供的是**"几何不再漂移"的护栏**，而不是"U-04 逻辑正确"的证明。
3. **测试的覆盖矩阵**（QA 明确要求）：**四角 × `scale` ∈ {0.8, 1.0, 1.3} × `margin` 正/负** —— 用于覆盖 `FloatingPanel.swift:96` 的 `margin = 20 - glowMargin * scale` 在三种尺寸下的取值与边界。
4. **落地安排**：U-04 的**代码修复**（值比较，约 5 行、低风险、可回滚）仍随第一批同行 —— 让一个已知缺陷在等待测试基建期间继续存在并不划算。但 **U-04 不得被标记为"已验证/关闭"**，直到 `originFor(...)` 的测试在 U-09 中落地。
5. **★ 给工程师的合并提示**：**U-04、U-12、U-13 是同一处改动的三个面** —— 都落在 `FloatingPanel.swift:70-88` 及其调用链上。**应一次改完、一次验证**，不要拆成三次提交，否则后一次改动会推翻前一次的观测基线。

---

### 3.3 P2 — 可选 / 择机

QA 报告中有 18 条 P2，架构师有 6 条 P2，去重后重点择要如下（完整清单见两份成员报告）：

- **U-11 退出路径的清理与落盘兜底（合并项）** —— 把 `FloatingPanel.swift:57-65` 的 `deinit` 死代码与 `main.swift:21-23` 的 Ctrl+C 不 flush **合并为一件事**处理，避免重复计数。两者本质相同：退出时没把最后 ≤1s 的样本落盘，且现有清理路径静默失效。修法：在 `AppDelegate.applicationWillTerminate` 显式调用 `@MainActor` 的 `shutdown()`（内部停 timer、flush 日志、摘除 RunLoop 源与观察者）。**架构师与 QA 对严重度曾有分歧（P2 vs P1），主理人裁定为 P2** —— `FloatingPanelController` 由 `AppDelegate.windowController` 强持有至进程退出，实际不会被释放，故"泄漏"不发生；但它是"意图明确却静默失效"的死代码，一旦控制器将来变为可释放就会立即变成真缺陷。（QA P1-2 + P2-17）

- **U-12 设置变更时的视图 churn + 两步动窗口**（`FloatingPanel.swift:77,81,82,117`）—— `applySettings()` 每次都 `NSHostingView(rootView: PowerHUDView(...))` **重建整棵 HUD 视图树**并重新赋给 `panel.contentView`。最高频触发路径是**拖动 TDP 滑块**（`SettingsView.swift:81` 每次 `onChange` 都 `commit()`），而 **TDP 只影响整机功率估算、根本不参与 HUD 布局 → 纯开销**。同一函数还**分两步**改窗口几何：`:82` `setContentSize`（旧原点 + 新尺寸）→ `:87`/`:117` `setFrameOrigin`。建议：hosting 只建一次、设置变更只更新 `scale`；几何合并为单次 `setFrame`（**与 U-04 的配套修法②同源，可一并做**）；TDP 变更不触发 `applySettings`。（QA P2-19）

- **U-13 两处死代码恰是"危险版本"**（`AppSettings.swift:68-73`、`PowerMonitor.swift:103-105`）—— `saveCustomPosition` 与 `refreshOnce` **全仓只有定义、没有调用点**（QA 自查发现、主理人已用 grep 独立复核）。**它们不是普通死代码**：<br>• `saveCustomPosition` **会**调用 `commit()`（触发 re-layout），而在用的 `rememberDrag`（`:76-84`）**刻意不调** —— 若后人"顺手"把它接到 `didMove` 观察者上（替换 `rememberDrag`），**U-04 的重入面立即成立**；<br>• `refreshOnce` 若被接上，就是一个**新的主线程采样入口**（U-01）。<br>**⚠️ 两个子项的严重度不对称，必须拆分标注**（QA 主动提出，主理人采纳）：<br>&nbsp;&nbsp;• **`refreshOnce` → P2（潜在 P0）** —— 它和 `start()`（`PowerMonitor.swift:89`）走的是**同一条 `scheduleSample()` 路径**，**一旦被接线即同步主线程采样，等于现场制造一个 P0**。死代码本身无害，但"引信"的量级高于普通死代码。<br>&nbsp;&nbsp;• **`saveCustomPosition` → P2** —— 接线后成立的只是重入面（U-04 形态）。<br>**建议：删除，或在注释里写明"为何不可直接接线"。** 留着比删掉危险 —— 它们看起来是"更规范的版本"，很容易被误用。（QA P2-20；本条已由 QA 提出、架构师 grep 独立复核确认，属**双方确认**档）

- **`FloatingPanel.swift` 职责拆分**（293 行含浮窗几何、菜单栏 68 行、设置窗口内联、图表窗口生命周期、位置持久化旁路）→ 抽 `MenuBarController` / `SettingsWindowController` / `PanelLayout`（纯函数），目标 ≤100 行。**注意 `rebuildMenuCheckmarks()` 当前是整体重建菜单，属"能跑但概念混淆"。**
- **`NSScreen.main` 多屏问题**（`FloatingPanel.swift:91`）→ 副屏上改位置/改尺寸会把挂件拽回主屏。
- **回填上限不一致**：`memoryCapacity = 200_000` 但 `historyBackfill = 40_000` → 重启后「24h」实际只有约 5.5h。要么提高上限，要么把预设文案改成"最近记录"。
- **环形缓冲退化为 O(n)**（`PowerLogger.swift:71`）：满载后每 0.5s 一次 `removeFirst(1)` 搬移约 12MB → 主线程周期抖动。建议攒批裁剪或改真环形缓冲。
- **健康度可能显示假的 ≈100%**（`Battery.swift:116-120`）：`DesignCapacity` 缺失时用 `MaxCapacity` 兜底，导致健康度恒 ≈100%。**电池健康度是用户做换电池决策的依据，建议显示"设计容量不可读"而不是一个体面的假数字。**
- **百分比未夹取 0...100**（`Battery.swift:35` + `PowerHUDView.swift:63`）→ `trim(to: >1)` 渲染异常。
- **`passthrough` 默认 true**（`AppSettings.swift:45`）→ 新用户首次运行完全不知道挂件可交互。
- **UserDefaults 域不一致**（`AppSettings.swift:41`）：`swift run` 与 `.app` 的设置不共享。
- **更新流程**：403 限流与 404 合并提示；临时文件中转 `try?` 静默失败；无重试/断点续传。
- **helper JSON 无时间戳**（`MacBatteryHelper/main.swift:43`）→ app 无法识别过期数据；`NaN`/`inf` 时产出非法 JSON。
- **`effectiveKey!` 强制解包**（`SMC.swift:43,53`）→ 建议改 `guard let` 并开 SwiftLint `force_unwrapping`。
- **`Updater` 的 `URLSession` 强持有 delegate** → 有界泄漏（非 P0）。
- **CI 仅 ad-hoc 签名**，README 未提示 Gatekeeper 首次打开限制（零成本改动）。
- **无卸载脚本**：`install_helper.sh` 有安装无卸载，README 让用户手动 `launchctl bootout` + 删两处路径。
- **README 三处漂移**：Windows 路径 `d:/Project/MacBattery`、"读不到显示 `--`"（实际有估算回退）、SMC 键列表。

---

## 四、落地顺序

**第一批（止损，全部低风险、可独立提交）**
1. **U-02** 第 1、2、3 点：`pmset` 先读管道 + 加超时 + 缓存从 2s 提到 5s
2. **U-01** 第 1 步：给三个静态缓存加锁（消除正确性风险，无副作用，不动调用结构）
3. **U-10**：UI 标注"估算值" + 设置面板说明
4. **U-05**：SMC 键三处同源 + 修 README 三处漂移
5. **U-08**：helper 加 `autoreleasepool`
6. **U-04**：值比较法（`lastProgrammaticOrigin` + ≤0.5pt 容差 + 首次 `didMove` 无条件清空）**+ 配套修法②**（将 `setContentSize` 与 `setFrameOrigin` 合并为单次 `setFrame`，与 U-12 同源）—— 免疫同步/异步，两种情形下均无副作用，**可先落地**。⚠️ **但 U-04 不得标记为"已验证/关闭"**，直到 `originFor(...)` 纯函数测试在 U-09 中落地（见 3.2.1）。实机确认后再决定是否升级为 `PanelPosition` 枚举

**第二批（并发模型拨正 + 数据完整性）**
7. **U-01** 第 2 步：`scheduleSample()` 改入队 + `BatteryHealthLogger` 硬件读取移出主线程 → **重新验证 1.1.9 的 merge 时序**
8. **U-01** 第 3 步：加 `dispatchPrecondition(.notOnQueue(.main))` 护栏（**必须晚于第 7 步**，否则误伤 health 采样）
9. **U-03**：`os.Logger` + 失败回填 `pending` + 容错解码 + 回填 merge 对齐健康日志
10. **U-11**：`deinit` 死代码 + Ctrl+C 不 flush 合并处理，改显式 `shutdown()`
11. **U-06**：CI 版本号一致性校验 + `workflow_dispatch` 版本输入

**第三批（结构与工程化）**
12. **U-09**：`MacBatteryCore` + test target + CI test job（**必须在动图表之前做**，让后续重构有护栏）。**首批测试必须包含 U-04 要求的 `originFor(...)` 几何纯函数** —— 它是 U-04 得以关闭的前置（见 3.2.1）
13. **U-13**：删除 `saveCustomPosition` 与 `refreshOnce` 两处死代码，或补上"不可直接接线"的注释 —— **建议尽早做**，它们是 U-04 与 U-01 的现成引信，且成本接近于零
14. **U-07**：图表基础设施抽取（**先抽 `ScrollWheelCatcher` 消除隐式文件依赖**，再抽坐标轴 / 几何 / 交互）
15. **U-12**：HUD 视图树重建与 TDP 变更解耦（几何合并已在第 6 项完成）
16. `FloatingPanel` 职责拆分；其余 P2 项择机清理

> 说明：以上是**顺序与范围**建议，不含日期或排期承诺。第 2、6 项互不依赖，可并行；第 5 项需 root 环境验证。

---

## 五、需要你决策的事项

以下问题无法从代码判断，且会改变优先级判定，请确认：

1. **发行目标**：只走 GitHub 分发，还是未来可能上 Mac App Store / 引入沙盒？
   → 若上沙盒，`pmset` 子进程（`Process` fork/exec）**会被系统直接禁止**，P0-B 立即升级为"必须整体移除"。
2. **Apple Developer Program（$99/年）**：是否有账号可用于 Developer ID 签名 + 公证？
   → 决定 ad-hoc 签名与 Gatekeeper 摩擦是"加一段 README"还是"做一次正式签名"。
3. **Apple Silicon 的产品定位**：是"Intel 优先的小众真实功耗工具"，还是"面向所有 Mac 的通用挂件"？
   → 决定 P1-I 走"诚实标注"（A）/ "探索 IOReport·powermetrics 真实数据源"（B）/ "Apple Silicon 上隐藏整机功率行"（C）。
4. **`pmset` 存在的历史原因**：是否曾实测发现某些 Intel 机型上 `kIOPSIsChargingKey` 滞后或缺失？
   → 若是，替代方案必须复现该机型才能动；若否，纯 API 路径可以尽早替换。
5. **两份 CSV 是否视为外部接口**（有别的脚本/工具在读）？
   → 若是，字段增删需版本化；若否，可自由演进。
6. **TDP 默认 45W 的来源**：某具体机型的额定值，还是随手取的默认？
7. **是否接受修改 `Package.swift`**（新增 `MacBatteryCore` library target）？
   → 测试方案依赖它。注：`MacBattery` 是 `executableTarget`，含 `main.swift` 顶层代码，SwiftPM 5.7 下直接测 executable target 链接行为不稳定，抽 library 是最小且长期正确的做法。
8. **手边的实机测试矩阵**（Intel / Apple Silicon 各有哪些机型）？
   → 决定 P0-A 竞态、P0-B 替换方案、P2 多屏问题能否被验证。

---

## 六、局限与免责

- **未编译、未运行**：环境为 Windows，无法执行 `swift build` / `swift test`。所有涉及运行期行为的结论均为**静态代码推断**。
- **行号基准**：`workbuddy/main-247e6f68` 工作区快照。行号漂移风险最高的是 `PowerChartView.swift`（915 行）与 `BatteryHealthChartView.swift`（704 行）——改代码时请以**函数名 + 就近行号**复核。
- **需实机确认的项**：QA 报告第六节列出 14 项，架构师二次核对后收敛为以下 **4 项最高优先**（其余见成员报告）：

| # | 待确认内容 | 决定什么 | 确认方法（保守，不依赖退出路径） |
|---|---|---|---|
| 1 | ① AppKit 是否对**程序化** `setFrameOrigin` 发出 `NSWindowDidMoveNotification`（Apple 无契约保证）；② `applySettings()` 一次调用实际发出**几条**通知（`didMove` 与 `didResize` 各几条） | U-04 升级为 P1 还是降为 P2（**U-04 的全部实际价值取决于 ①**） | **给工程师的推荐做法**：**同时挂两个计数观测者（`didMove` + `didResize`），一次运行即可同时回答 ① 与 ②**，不必分开测。只加观察者、不改行为。**建议保守观察，勿依赖退出路径确认** —— 退出路径的落盘/清理当前正受 U-11 影响，用退出日志验证会引入混淆。**注意**：U-04 的配套修法②（合并 `setContentSize` + `setFrameOrigin` 为单次 `setFrame`）会把 ② 从"不确定"变为"确定 1 条"，因此**建议先做配套修法再观测** |
| 2 | `PowerMonitor` 主线程采样与队列采样是否真的并发重叠 | U-01 的实际触发概率（机制已确定，待测频率） | 在 `Sampler.sample` 首行记 `Thread.current`，连续做"休眠-唤醒-插拔"20 次统计命中数 |
| 3 | 休眠唤醒后 `AppleSmartBattery` 句柄是否真的失效 | U-01 的触发前提是否成立 | 在 `Battery.swift:53` 的句柄重建分支记 `notice`，观察唤醒后是否命中 |
| 4 | 「系统菜单栏电池图标状态」vs「`pmset -g batt` 文本」vs「盘位电池驱动暴露的**电量计数**（Intel `PUSH` / Apple Silicon `BAT0` 的 **pull 次数**）」三者的**变更延迟** | `pmset` 能否被纯 API 替代（U-02 第 4 点）、`pmsetCache` 缓存时长能否安全放宽 | 采集原始观测数据对比时间轴。**注意**：`kIOPSIsChargingKey` 与 `kIOPSPowerSourceStateKey` 是"与菜单栏同源"，若观测到**同时不更新**，则**需先向用户说明这一风险**，替换方案须重新评估；此项**排在 1-3 之后**，不阻塞 |

- **建议的实测方式**：不用改逻辑，只在一处补日志；随后**放 2 小时以上**采集真实状态转换。30 秒一次采 10 分钟已经能看出趋势，可先短测快速判断。
- **成员报告**：本方案是汇编与裁定，不是替代。完整论证、逐条行号引用与测试用例设计见同目录两份成员报告。

---

## 七、附：本次评审的完整交付物

| 文件 | 产出者 | 内容 |
|---|---|---|
| `macbattery-modification-plan-2026-09-15.md` | 齐活林（主理人） | 本文件：交叉印证、分歧裁定、统一优先级、落地顺序、决策项 |
| `macbattery-architecture-review-2026-09-15.md` | 高见远（架构师） | 8 大主题、Mermaid 现状→目标图、必须改/可以不改分界、待明确事项 |
| `macbattery-quality-review-2026-09-15.md` | 严过关（QA 工程师） | 23 条缺陷清单、4 层测试策略、可测试性改造清单、30 项发布前冒烟清单、SwiftLint 配置 |
