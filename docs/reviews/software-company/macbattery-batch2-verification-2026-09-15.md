# MacBattery 第二批修复 · 独立验收报告

- 验收人：严过关（QA Engineer）
- 日期：2026-09-15
- 被测提交：`d671133`（父 `5fe8944`，链 `23bc728 → 5fe8944 → d671133`）—— 父提交已用 `git rev-parse d671133^` 核实为 `5fe8944e2b7895fc3d44e3e8c798f5251db2f96b`，**非** root commit `668aefb`
- 改动集（`git show --stat d671133`）：7 文件 +283/−52
  `.github/workflows/build-dmg.yml`、`BatteryHealthLogger.swift`、`FloatingPanel.swift`、`PowerLogger.swift`、`PowerMonitor.swift`、**新增** `SampleMerge.swift`、`main.swift`
- 方法：静态审查 + 逻辑推演；**唯二可真跑的验证已在本地执行**：CI 的 `sed`/`grep` 正则（见 ③-8，附真实输出）。未修改任何源码。
- 环境说明：`refs/heads/workbuddy/*` 被外部移除导致 HEAD unborn —— 属已知现象，不计入缺陷。

---

## ① 验收结论

**通过（可推送）。**

一句话理由：5 项修复逻辑自洽、`dispatchPrecondition` 的两个受保护点经全仓穷举确认**无主线程路径**、CI 三条正则已在本机真跑全部命中预期、无越界改动；仅存 **8 条 P2 观察**（其中 1 条为本批新引入的窄窗口竞态，2 条为 CI 加固建议），**无 P0、无 P1**。

---

## ② 逐项验收结果

### U-01 第 2 步（采样移出主线程）—— **通过**

- `scheduleSample()` 改为只入队：`PowerMonitor.swift:133-136`，`sampleQueue.async { [weak self] in self?.performSampling() }`（原为就地 `performSampling()`）。
- `performSampling()` 保留 TDP 刷新行：`PowerMonitor.swift:149` `self.tdpBox.value = self.settings.tdpWatts`，并加"唯一通道"警示注释（`:144-148`）。
- `TDPBox` 加 `NSLock`：`PowerMonitor.swift:202-215`（`private let lock` + `private var storage` + 计算属性 `value` 的 get/set 各 `lock/defer unlock`）。
- `BatteryHealthLogger` 硬件读取拆到 `readQueue`：新增队列 `BatteryHealthLogger.swift:43`；`sample()`（`:98-108`）只入队；新增 `@MainActor applySample(health:level:force:)`（`:112-133`）承接原正文。
- 主线程入口确认无残留：全仓 grep `performSampling` 仅 2 个调用点 —— `:126`（`sampleQueue` 上的定时器 handler）、`:135`（入队）；`Sampler.sample` 仅 `:141`（在 `performSampling` 内）。

### U-01 第 3 步（护栏断言）—— **通过**（附 1 条重要语义澄清，见 ④-8）

- `PowerMonitor.swift:27`：`Sampler.sample(tdp:)` 首行 `dispatchPrecondition(condition: .notOnQueue(.main))`。
- `BatteryHealthLogger.swift:101`：`readQueue.async` 闭包首行同断言。
- 全仓 grep `dispatchPrecondition` **仅此 2 处**；无 `PreviewProvider` / `#Preview` / `XCTest` 等其它入口（grep 全仓确认）。

### U-03（历史静默丢失）—— **通过**

- 新增 `SampleMerge.swift:17-34` 泛型 `mergedByTimestamp(history:new:timestamp:capacity:)`。
- `PowerLogger.backfillHistory()` 由覆盖改为合并：`PowerLogger.swift:98-105`（原 `self.samples = history`）。
- `BatteryHealthLogger.backfillHistory()` 改用同一函数、删除私有 `merge`：`BatteryHealthLogger.swift:169-176`（原 `merge()` 已删除）。
- `import os` 两处均加：`PowerLogger.swift:3`、`BatteryHealthLogger.swift:3`；`Logger` 定义 `:124` / `:185`。
- 失败改 do/catch 记录：`createFile`（`PowerLogger.swift:203-206` / `BatteryHealthLogger.swift:263-266`）、`FileHandle(forWritingTo:)`（`:208-214` / `:268-274`）、`h.close()`（`:148-154` / `:209-215`）、`removeItem`（`:159-165` / `:220-226`，且文件不存在时不记错）。
- 48MB 截断告警：`PowerLogger.swift:273-275` / `BatteryHealthLogger.swift:333-335`。
- 分块解码改 `String(decoding:as:)`：`PowerLogger.swift:254` / `BatteryHealthLogger.swift:315`，删除原 `guard ... else { break }`。

### U-11（退出清理）—— **通过**

- 新增 `@MainActor shutdown()`：`FloatingPanel.swift:73-90` —— `monitor.stop()`（`:83`）、`healthLogger.stop()`（`:84`）、摘观察者并置 nil（`:85-88`）、`window?.close()`（`:89`）。
- `main.swift:21-25`：`applicationWillTerminate` 由 `close()` 改为 `shutdown()`。
- `deinit` 精简为只摘观察者：`FloatingPanel.swift:62-72`（删除原无效的 `Task { [weak self] }`）。
- 确认未引入 SIGINT/SIGTERM 处理器（grep 全仓无 `signal(` / `DispatchSource.makeSignalSource`）。

### U-06（CI 版本号）—— **通过**（正则已本机真跑，见 ③-8）

- `workflow_dispatch.inputs.version`：`build-dmg.yml:8-13`（required / string）。
- 新增 `Resolve release version`（`:30-46`，`id: version`）与 `Check version consistency`（`:49-62`），均在 `steps:` 下、Build（`:64`）之前；缩进与既有 `- name: Checkout` 一致（6 空格 + `- `）。
- PlistBuddy 写入由"仅 tag 分支"改为无条件：`:91-94`（`VER="${{ steps.version.outputs.version }}"`）。

---

## ③ 你要求的 9 类问题 · 各自结论

**1. `dispatchPrecondition` 会不会误触发 —— 不会。已独立穷举，不接受你的结论，自己核了一遍：**

| 受保护点 | 调用路径穷举 | 所在队列 |
|---|---|---|
| `Sampler.sample(tdp:)`（`PowerMonitor.swift:27`） | 唯一调用点 `PowerMonitor.swift:141`，位于 `performSampling()` | — |
| ↳ `performSampling()` 调用点 1 | `PowerMonitor.swift:126`，`DispatchSource.makeTimerSource(queue: sampleQueue)` 的 handler（`sampleQueue` = `DispatchQueue(label:"MacBattery.sample")`） | 后台串行队列 ✅ |
| ↳ `performSampling()` 调用点 2 | `PowerMonitor.swift:135`，`sampleQueue.async { … }` | 后台串行队列 ✅ |
| ↳ `performSampling()` 调用点 3 | **不存在**（`refreshOnce()` `:113-116` 全仓无调用点，grep 确认只有定义与函数体两行） | — |
| `BatteryHealthLogger` 读取块（`:101`） | 唯一入口 `readQueue.async`（`:99`），`readQueue` = `DispatchQueue(label:"MacBattery.health.read")` | 后台串行队列 ✅ |

- 另已确认：`Sampler` **未被** SwiftUI 预览调用（全仓无 `PreviewProvider` / `#Preview`），无测试 target（`Package.swift` 无 testTarget，全仓无 `XCTest`）。
- 主线程入口（`start()` `:100`、`powerSourceChanged()` `:195`、`recordNow()` `:77`、`applySettings()`）现在**只入队或只更新 UI**，不再直连硬件读取。
- **结论：两处断言在任何已知路径下都不会触发。** ⚠️ 但语义澄清见 ④-8：它在 release 构建下**依然生效**，不是"仅开发期"。

**2. TDP 传播链 —— 完整，行 `:149` 确实是唯一通道且未被删。**
- 链：设置滑块 → `SettingsView.swift:39/84` `.onChange(of: store.tdpWatts) { store.commit() }` → `SettingsStore.commit()`（`AppSettings.swift:55-65`）→ `onChange?()` → `FloatingPanelController.applySettings()`。
- **`applySettings()` 不碰 TDP、也不调 `scheduleSample()`**（`FloatingPanel.swift:75-99`）→ 所以 `:134` 那条写入不会在改 TDP 时命中。
- 因此 TDP 只能靠 `performSampling()` 主线程收尾的 `:149` 传播 → **最迟 0.5s 生效**（定时器周期），功能可用。
- 顺序细节：`:141` 先用**旧** TDP 采样，`:149` 才更新 → 改 TDP 后第一拍用的是旧值，偏差一拍（0.5s），无害。
- `TDPBox` 死锁面：`NSLock` 只在 `value` 的 get/set 内持有，期间**只访问 `storage`**；`:141` 的 `tdpBox.value` 在**进入 `Sampler.sample` 之前**已求值并释放；`:149` 的 setter 在 RHS（`settings.tdpWatts`，无锁）求值后才加锁。**不与其它任何锁嵌套，不跨子进程持有 → 无死锁。**

**3. `BatteryHealthLogger` 异步化时序 —— 两种顺序都成立，工程师的说法经独立推演为真。**
- `guard samples.isEmpty`（`:164`）是**调用时同步求值**：`start()` 中 `backfillHistory()`（`:57`）先于 `sample(force:true)`（`:66`），此刻 `samples` 必为空 → 守卫照常通过 ✅（注释 `:158-160` 的说法正确）。
- (a) **回填先到**：`samples == []` → `mergedByTimestamp(history, [])` = 历史本身 → 赋值；`lastRecorded = samples.last`（历史最新点）。随后 `applySample(force:true)` → `append()` 把启动点追加到末尾，`Date()` 晚于所有历史点 → **升序保持** ✅
- (b) **启动点先到**：`samples == [启动点]` → 合并历史与该点，两者都在、按时间升序 ✅ `lastRecorded` 被 `:175` 重设为 `samples.last` = 启动点（最新），与路径 (a) 的"历史最新点"在语义上一致（都是当前最新）✅
- `generation` 校验：`:165` 调用时快照、`168` 回调比对，与到达顺序无关 ✅
- **`recordNow()` 变异步后的副作用**：`FloatingPanelController.openHealthChart()`（`:277`）`recordNow()` 后立即 `showWindow`，新点可能在窗口显示**之后**才落内存。文档 `:74` 仍写"立即采样一次…保证每次打开都留档"与 `:75-76` 的新取舍说明**互相矛盾**（措辞需修，见 ④-7）。功能上因 `samples` 是 `@Published`，点到达后会自动刷新，无用户可见错误。
- **新引入的窄窗口问题**：`reset()`（`:82-88`）不校验 `generation`，在途 `applySample` 会在 reset 之后追加并写盘 → 见 ④-1。

**4. `mergedByTimestamp` 正确性 —— 正确（1 处语义不确定的 P2）。**
- 去重：`:22-29` 相同时间戳后者覆盖前者 ✅；升序：`:21` `sorted { timestamp($0) < timestamp($1) }` ✅；裁剪方向：`:30-32` `removeFirst` 从**最旧**端裁 ✅；空输入 / `new` 空 / `history` 空：pooled 为对应一侧，`>capacity` 时 0 不大于 capacity → 原样返回 ✅。
- **capacity 传值核对**：`PowerLogger.swift:101` 传 `Self.memoryCapacity` = **200_000**（`PowerLogger.swift:29`）✅；`BatteryHealthLogger.swift:172` 传 `Self.memoryCapacity` = **2000**（`BatteryHealthLogger.swift:24`）✅ —— 两处都传的是**各自类的** `memoryCapacity`，**未串用**，正确。
- 图表升序假设：返回数组严格升序（去重后相邻不同时间戳），`BatteryHealthChartView.swift:424-425`/`PowerChartView` 的 `first?.t`/`last?.t` 用法成立 ✅
- ⚠️ **P2**：Swift 的 `sorted(by:)` **不保证稳定**，因此"同时间戳时 `new` 覆盖 `history`"这个文档承诺（`:14`、`:24-25`）**并未真正被保证** —— 相等键的相对顺序未定义。当前实际影响≈0（同时间戳的两条内容等价），但属于"注释与实现不符"。见 ④-2。

**5. `String(decoding:as:)` 替换的副作用 —— 无副作用，且不可能比旧写法更差。**
- `leftover` / `lines.dropFirst()` 逻辑**逐字保留**：`text += leftover` → `split("\n")` → `offset > 0` 时 `leftover = lines.first` 并 `dropFirst()` → `lines.reversed()` 解析。倒序分块 + 尾部拼接的语义正确（块 N 的文本 + 上一轮的 `leftover` = 连续区段；再取其首行作为新的不完整行）✅
- 非法字节 → U+FFFD → 只影响**该行** → `parseCSVLine` 的 `Double(epochString)` 失败返回 nil → 该行被跳过 ✅（符合注释声明）
- 老 `guard ... else { break }` 删除后，`data` 为空时 `String(decoding: Data(), as:)` = `""`，`lines` 为空，`offset > 0 && !lines.isEmpty` 为假 → `leftover = ""`，循环继续 → 不会死循环 ✅
- ⚠️ 诚实补充：本 CSV **纯 ASCII**（只有数字/逗号/点/表头），"块边界落在多字节字符中间"在本文件格式下**不会发生**；该改动是纯防御性加固，不是 bug 修复。
- ⚠️ **P2**：新增的截断告警（`:273-275` / `:333-335`）在**读取失败**时也会被触发（`guard let fh = try? … else { break }` 与 `catch { break }` 同样导致 `offset > 0 && result.count < limit`），会把"打不开文件"误报成"文件过大"。且这几处仍是 `try?` 静默吞错，与本次"IO 失败不静默"的目标不一致。见 ④-3。

**6. `os.Logger` —— 可用，两处 `import os` 都在，插值用法成立。**
- `import os`：`PowerLogger.swift:3` ✅、`BatteryHealthLogger.swift:3` ✅
- `Logger(subsystem:category:)`：`:124` / `:185` ✅
- 插值类型：`\(url.path, privacy: .public)`（String）、`\(error.localizedDescription, privacy: .public)`（String）、`\(offset, privacy: .public)`（Int）—— `OSLogInterpolation` 对 `String` 有专用重载，对 `Int` 至少可走 `CustomStringConvertible` 泛型重载，**均成立** ✅
- 可用性：`Package.swift:6-8` `platforms: [.macOS(.v12)]` → macOS 12，`Logger` / `.error(_:)`（macOS 11+）可用 ✅。⚠️ 小提示：`.warning(_:)` 属于较晚加入的级别（macOS 12 级），与本项目 target 一致，但**建议首次真机 `swift build` 时确认一次**；若报不可用，退路是 `logger.log(level: .default, …)` 或改用 `.error`。

**7. U-11 —— 不会重复调用、不与 `deinit` 冲突；`monitor.stop()` 确实级联到 `flushPending()`（已读代码核实，未假设）。**
- 级联链核实：`FloatingPanel.shutdown()` `:83` → `PowerMonitor.stop()`（`PowerMonitor.swift:103-111`）→ `:106` `logger.stop()` → `PowerLogger.stop()`（`PowerLogger.swift:58-62`）→ `flushPending()` ✅ 你的判断成立。
- 重复调用：`applicationWillTerminate` 只触发一次（全仓 `shutdown()` 调用点仅 `main.swift:24`）；且 `shutdown()` 本身幂等（`sampleSource?.cancel()` 对 nil 安全、`flushPending()` 二次调用被 `guard !pending.isEmpty` 挡住、`window?.close()` 幂等）✅
- 与 `deinit` 冲突：`shutdown()` 已把 `moveObserver` 置 nil（`:88`），`deinit`（`:62-72`）再判 `if let` 为空 → 不会重复 `removeObserver` ✅
- ⚠️ **P2**：`shutdown()` 未解绑 `settings.onChange`、未移除 `statusItem`、未停 `updater`；`healthLogger.stop()` 也**不取消在途的 `readQueue` 任务**（退出瞬间可能有一次健康点在 stop 之后落盘/被丢弃）。影响很小，见 ④-4。

**8. ★ CI 正则 —— 已在本机真跑，三条全部符合预期（附真实输出）。**

```
PWD=/c/Users/zioon/WorkBuddy/Worktrees/MacBattery/main-247e6f68
--- 0a fallback lines ---
11:    static let fallback = "1.1.11"          ← 全文件唯一匹配行
18:        return fallback                      ← 不匹配（无 static let fallback =）
rc=0
--- 0b changelog headings ---
7:## [1.1.11] - 2026-09-15
27:## [1.1.10] - 2026-09-15
...
--- 1 sed ---
SRC=[1.1.11]                                   ← 期望 1.1.11  ✅ PASS
--- 2 ---
grep -q "^## \[1.1.11\]" CHANGELOG.md → rc=0    ← 期望 0      ✅ PASS
--- 3 ---
grep -q "^## \[1.1.12\]" CHANGELOG.md → rc=1    ← 期望非 0    ✅ PASS
```
- 补充验证：`Updater.swift` 中 `static let fallback = "` 只有第 11 行匹配，`head -n1` 取到的就是它（第 18 行 `return fallback` 不命中）→ `sed|head` 组合无歧义 ✅
- `CHANGELOG.md` 已 `git ls-files` 确认为**已跟踪**文件（CI checkout 后存在）✅
- YAML 结构：`steps:`（`:24`）下新增两步与 `- name: Checkout` 同级（6 空格 + `- `），且位于 Build（`:64`）之前 ✅
- ⚠️ 另跑的额外探测：`grep '^## \[1.1.1.\]'` **rc=0**（点号是正则元字符）—— 说明 `VER` 被当作正则而非字面量；当前因有 `]` 锚定不会误判，但建议改 `grep -qF`。见 ④-5。

**9. 越界改动检查 —— 无越界。**
`git show --stat d671133` 的 7 个文件即全部改动；`PowerChartView.swift` / `BatteryHealthChartView.swift` / `Updater.swift` / `Package.swift` / `AppSettings.swift` / `Battery.swift` / `SMC.swift` / `SystemPower.swift` / `PowerHUDView.swift` / `SettingsView.swift` / `MacBatteryHelper/` / `SMCBridge/` **均不在改动集** ✅
（`Updater.swift:11` 的 `1.1.11` 来自上一提交 `5fe8944` 的 bump，非本批。）

---

## ④ 新发现的问题

### P2-1（本批新引入）`reset()` 与在途 `applySample` 竞态 —— reset 不再"清空干净"
- **文件:行**：`BatteryHealthLogger.swift:82-88`（`reset()`）与 `:98-108`（`sample()`）/ `:112-133`（`applySample`）。
- **触发条件**：`sample()` 已投 `readQueue`、IOKit 读取完成、`Task { @MainActor }` 尚未执行时，用户触发 `reset()`（`BatteryHealthChartView.swift:447` 的"清空历史"按钮）。
- **机理**：`reset()` 把 `generation += 1` 并清空 `samples`，但 `applySample` **完全不校验 `generation`**（对比 `backfillHistory` 的 `:168` 有校验）。在途那次采样随后在主线程落地 → `append()` → `samples` 被塞回 1 个陈旧点，并 `store.write([f])` 写回磁盘（ioQueue 上排在 `clearDisk()` 之后 → 文件被重建并写入该点）。
- **影响**：点"清空历史"后健康曲线立刻回潮 1 个点。窗口约等于一次 `BatteryReader.health()+level()` 的耗时（毫秒级），**很窄**；但**改动前 `sample()` 是同步的，该窗口不存在**，属本批新引入的回归面。
- **修法（2 行）**：在 `sample()` 的 `readQueue` 闭包开头快照 `let gen = self?.generation`（或直接在闭包内读 `generation` 前先 `guard let self` 取到强引用再读），把它带进 `applySample`，在 `applySample` 首行加 `guard generation == gen else { return }`；同时让 `reset()` 也 `+= 1`（已有）。

### P2-2 `mergedByTimestamp` 的去重优先级未被真正保证（注释与实现不符）
- **文件:行**：`SampleMerge.swift:21`（`.sorted {}`）、文档 `:14`/`:24-25`。
- **触发条件**：`history` 与 `new` 存在相同时间戳时。
- **影响**：Swift 的 `sorted(by:)` **不保证稳定**，相等键相对顺序未定义 → "后者（`new`）覆盖前者"可能反过来。当前实际影响≈0（同时间戳两条内容等价）。
- **修法**：给排序加稳定次序，例如
  `let pooled = (history.map { (t: timestamp($0), r: 0, v: $0) } + new.map { (t: timestamp($0), r: 1, v: $0) }).sorted { ($0.t, $0.r) < ($1.t, $1.r) }.map(\.v)`，之后再跑现有去重逻辑。

### P2-3 截断告警会误报"文件过大"，且读路径仍有静默 `try?`
- **文件:行**：`PowerLogger.swift:273-275` / `BatteryHealthLogger.swift:333-335`（告警）；`:246,248,249` / `:307,309,310`（`try? FileHandle(forReadingFrom:)`、`catch { break }`、`try? fh.read(...)`）；`:233` / `:294`（`try? attributesOfItem`）；`:218` / `:278`（`try? h.seekToEnd()`）。
- **影响**：文件打不开/读取失败时会打出"历史文件过大，回填被截断"，误导排障；同时这些失败仍被静默吞掉，与本次"IO 失败不静默"的目标不一致。
- **修法**：把 `break` 改为"记 error 后 break"，并引入一个 `truncated` 布尔只在**读满 48MB** 时置真，告警条件改为 `if truncated && result.count < limit`。

### P2-4 `shutdown()` 覆盖不完整
- **文件:行**：`FloatingPanel.swift:73-90`。
- **影响**：① 未解绑 `settings.onChange`（`:48` 注入），退出过程中若触发设置变更仍会 `applySettings()`；② 未移除 `statusItem` / 未停 `updater`；③ `healthLogger.stop()`（`:69-72`）只 `invalidate` 定时器，**不取消在途 `readQueue` 任务**，退出瞬间可能有一次健康点写入或丢失。
- **修法**：在 `shutdown()` 里补 `settings.onChange = nil`、`statusItem` 清理；给 `BatteryHealthLogger` 加一个 `isStopped` 标志并在 `applySample` 首行 `guard !isStopped`。影响很小，可与 P2-1 一起改。

### P2-5（CI）`workflow_dispatch` 输入被直接插进 shell —— 脚本注入面
- **文件:行**：`build-dmg.yml:34,35`（`${{ github.event.inputs.version }}` 进 `if`/赋值）、`:52`、` :91`（`${{ steps.version.outputs.version }}`，其值源自同一输入）。
- **触发条件**：任何能触发 `workflow_dispatch` 的人（默认需 repo write 权限）传入形如 `1.1.12"; <任意命令>; echo "` 的值。
- **影响**：命令注入到 runner（该 job 有 `contents: write` 与 `GH_TOKEN`）。属已知 GH Actions 反模式；实际风险受"需写权限"约束，但**修法零成本**。
- **修法**：改为经 `env:` 传值再引用：
  ```yaml
  - name: Resolve release version
    id: version
    env:
      INPUT_VERSION: ${{ github.event.inputs.version }}
    run: |
      if [ -n "$INPUT_VERSION" ]; then VER="$INPUT_VERSION"; ...
  ```
  后续两步同样用 `env: STEP_VERSION: ${{ steps.version.outputs.version }}` + `"$STEP_VERSION"`。

### P2-6（CI）`git describe` 回退在默认浅克隆下必然失败
- **文件:行**：`build-dmg.yml:39`（`VER="$(git describe --tags --abbrev=0 …)"`）。
- **触发条件**：既非 `workflow_dispatch`（无输入）、也非 `v*` tag push 时走到该分支；`actions/checkout@v4` 默认 `fetch-depth: 1`，**不拉 tag** → `git describe` 失败 → `VER` 为空 → `:41-44` 报"无法确定版本号"并 `exit 1`。
- **影响**：该回退分支实际不可用（不会静默产出错版本，会明确报错退出 —— 行为是安全的），但与注释"回退到最近的 tag"不符。
- **修法**：给 Checkout 加 `with: fetch-depth: 0`，或删掉该回退分支只保留两种来源。

### P2-7 文档自相矛盾 / 措辞过期
- `BatteryHealthLogger.swift:74` 仍写"**立即**采样一次…保证每次打开都留档"，与 `:75-76` 新增的"不再同步完成"取舍说明直接冲突 → 建议把"立即"改为"触发一次（异步）"。
- `PowerMonitor.swift:85` 注释仍写"值为 Double，竞争可忽略"，但 `TDPBox` 已改为 `NSLock` → 建议同步更新。
- `PowerLogger.swift:104`：`samples` 是 `@Published`（`:35`），赋值本身会发 `objectWillChange`；这里**多发一次** → 一次多余的整体 body 求值（启动期一次，代价低但无必要）。建议删掉 `:104` 那行（保留 `:102-103` 的早退判断即可）。

### P2-8 `dispatchPrecondition` 是"线上护栏"，不是"开发期护栏"（语义澄清，非缺陷但影响风险定级）
- **文件:行**：`PowerMonitor.swift:25-26`、`BatteryHealthLogger.swift:100` 的注释都写"开发期立刻崩溃"。
- **澄清**：Swift 的 `dispatchPrecondition` 内部基于 `precondition`，而 `precondition` 在 **`-O`（release）下依然生效**，只有 `-Ounchecked` 才被移除。SPM 的 `swift build -c release` 是 `-O` → **该断言在发布版里同样会崩溃进程**，不是"仅开发期"。
- **结论**：① 当前两条断言经 ③-1 穷举确认无主线程路径，故**不会真的崩**；② 但注释低估了后果，**未来任何人新增一条主线程调用路径 = 线上崩溃**，不是"开发期发现"。建议在注释里把"开发期"改为"发布版同样崩溃，新增入口前务必确认调用队列"。
- （若想彻底零风险，可改用 `Thread.isMainThread` + `os.Logger` 记日志而不 trap；但那就失去了"钉死"的价值 —— 我倾向**保留断言 + 修正注释**。）

### 说明：**无 P0、无 P1。**

---

## ⑤ 我无法确认 / 需真机（或工具链）验证的项

1. **编译**（本机无 Swift）—— 本批新增 5 类语法/API 面，需 `swift build` 一次性确认：
   `dispatchPrecondition`、`String(decoding:as: UTF8.self)`、`os.Logger` 的 `.warning/.error` 与 `privacy:` 插值、文件级泛型函数 `mergedByTimestamp`、`NSLock` 计算属性、`BatteryReader.BatteryHealth` 跨线程传值。
   - 其中**我最想先确认的一条**：`Logger.warning(_:)` 在 macOS 12 SDK 下是否可用（target 正好是 12，边界情况）。
2. **`dispatchPrecondition` 在 `-O` 下是否真的仍生效**（决定 ④-8 的风险定级；依 Swift `precondition` 语义推断为"是"）。
3. **P2-1 的实际窗口宽度**：一次 `BatteryReader.health()+level()` 的真实耗时（若 >100ms，窗口就从"理论"变成"可复现"）。
4. **异步健康采样的观感**：打开健康窗口时新点的到达延迟是否可接受（`recordNow()` 不再同步）。
5. **CI 全链路**：本机只验证了三条正则片段；`workflow_dispatch` 与 `v*` tag push 两条真实路径需在 GitHub 上各跑一次。
6. **运行时**：退出路径（`shutdown()`）是否真的让最后一次 `flushPending()` 落盘成功（需在退出后用 `wc -l` 比对 CSV）。

---

## ⑥ 是否可推送 —— 建议

**建议：可推送（前提是第 ⑤-1 条"编译"能过）。**

理由：5 项修复目标达成、无 P0/P1、无越界改动、CI 三条正则本机真跑通过、并发护栏的两处断言经穷举无主线程路径。

推送前/推送后建议的处理顺序：
1. **先 `swift build`**（唯一能真正证伪本批的手段）。若 `Logger.warning` 报不可用 → 退到 `logger.log(level:)`。
2. **随本批一起修（成本极低、强烈建议）**：**P2-1**（`applySample` 加 `generation` 校验，2 行 —— 它是本批唯一新引入的回归面）、**P2-5**（CI 输入改走 `env`，零成本安全加固）。
3. **可并入下批**：P2-2、P2-3、P2-4、P2-6、P2-7（含删掉 `PowerLogger.swift:104` 的重复 `objectWillChange.send()`）。
4. **必改注释**：**P2-8** —— 把"开发期崩溃"改准确，否则后续维护者会低估新增入口的后果。
5. 未 push、未打 tag 的现状正确；`668aefb`（废弃 root commit）**不要采信、不要推**，`d671133` 的父提交已核实为 `5fe8944`，链正确。

---

### 附：本次验收实际执行的命令与证据源
- `git show --stat d671133`、`git rev-parse d671133^`、`git ls-files CHANGELOG.md Sources/MacBattery/SampleMerge.swift`
- `git show d671133 -- <7 个文件>`（逐行核验）
- **本机真跑**（`/c/Program Files/Git/usr/bin/{sed,grep,head}`）：
  `sed -n 's/.*static let fallback = "\([0-9A-Za-z.-]*\)".*/\1/p' … | head -n1` → `1.1.11`；
  `grep -q "^## \[1.1.11\]" CHANGELOG.md` → `0`；
  `grep -q "^## \[1.1.12\]" CHANGELOG.md` → `1`；
  外加 `grep '^## \[1.1.1.\]'` → `0`（用于暴露正则元字符面）
- ripgrep 全仓：`Sampler\.sample|refreshOnce|performSampling|scheduleSample|PreviewProvider|#Preview|XCTest|dispatchPrecondition|mergedByTimestamp|memoryCapacity|historyBackfill|reset\(\)|import os|platforms`
