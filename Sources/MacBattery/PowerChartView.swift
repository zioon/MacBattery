import SwiftUI
import AppKit
import MacBatteryCore

/// 可缩放 / 可拖拽的多系列折线图，支持主副双纵轴。
///
/// 轴划分：
/// - **左轴（主，固定 0–100%）**：电池 / CPU / RAM。
/// - **右轴（副，按真实数值自适应）**：整机功率 W / 充电功率 W / 电压 V / 电流 A。
///
/// 交互：
/// - 拖拽：左右平移时间；上下平移右轴（真实数值）缩放。
/// - 滚轮 / 触控板：纵向滚动缩放时间窗；Option+纵向滚动缩放真实数值轴；
///   双指横向滑动平移时间。
/// - 「适合窗口」一键回到全部数据并复位右轴自适应。
///
/// 用 SwiftUI `Canvas` 自绘（macOS 12 不支持 Swift Charts），
/// 数据源实时取 `PowerLogger.samples`，随采样自动刷新。
struct PowerChartView: View {

    @ObservedObject var logger: PowerLogger
    /// 语言变化时驱动本视图重绘（不必额外注入参数，直接观察共享实例）。
    @ObservedObject private var localization: LocalizationManager

    // MARK: 可见范围与缩放状态

    /// 当前可见的时间跨度（秒）。
    @State private var timeRange: TimeInterval = 30 * 60
    /// 可视窗口右缘（最新时间）。
    @State private var endTime: Date = Date()
    /// 右轴（真实数值）范围：功率 W / 电压 V / 电流 A。百分比主轴固定 0–100%。
    @State private var rightMin: Double = 0
    @State private var rightMax: Double = 100
    /// 右轴是否跟随数据自适应。
    @State private var autoRight = true
    /// 右轴是否已完成首次适配（初始默认 0–100，拿到数据后直接跳变到目标一次）。
    @State private var rightAxisInitialized = false

    /// 是否实时跟随最新数据。默认开启；用户拖拽平移或横向滚动到历史时自动关闭；
    /// 「适合窗口」会恢复。跟随期间右缘始终贴住最新样本。
    @State private var followLive = true

    /// 拖拽基准（手势开始时记录，保证平移严格跟手、不累积偏差）。
    @GestureState private var dragBase: DragBase?

    /// 一次拖拽的起始时间右缘。
    private struct DragBase {
        let endTime: Date
    }

    /// 鼠标在图表内的悬停位置（相对画布全尺寸，y 向下，nil 表示已离开）。
    @State private var hoverPoint: CGPoint?

    // MARK: 系列开关

    @State private var showBattery = true
    @State private var showSystemW = true
    @State private var showChargingW = true
    @State private var showCpu = true
    @State private var showRam = false
    @State private var showVoltage = false
    @State private var showCurrent = false

    // MARK: 布局常量

    private let leftPad = 52.0
    private let rightPad = 50.0
    private let topPad = 16.0
    private let bottomPad = 28.0

    private var minView: TimeInterval { 15 }          // 最小可见跨度
    private var maxView: TimeInterval { 24 * 3600 }   // 最大可见跨度
    /// 底部快捷时间窗口预设（秒）：5 分钟 / 30 分钟 / 1 小时 / 24 小时。
    static let windowPresets: [TimeInterval] = [5 * 60, 30 * 60, 60 * 60, 24 * 60 * 60]
    private let percentRange: ClosedRange<Double> = 0...100

    init(logger: PowerLogger) {
        self.logger = logger
        self.localization = LocalizationManager.shared
        _endTime = State(initialValue: Date())
    }

    var body: some View {
        VStack(spacing: 8) {
            legend
            chart

            HStack(spacing: 12) {
                Text(summaryText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(L("chart.history.axis_hint"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                // 时间窗口快捷切换：5m / 30m / 1h / 24h / 全部（当前选中项高亮）。
                windowPresetButton("chart.window.5m", Self.windowPresets[0])
                windowPresetButton("chart.window.30m", Self.windowPresets[1])
                windowPresetButton("chart.window.1h", Self.windowPresets[2])
                windowPresetButton("chart.window.24h", Self.windowPresets[3])
                Button(L("common.all")) { fitToAll() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(activeWindowPreset == nil ? .semibold : .regular))
                    .foregroundColor(activeWindowPreset == nil ? Color.accentColor : .primary)
                Button(L("common.reset_data")) { confirmReset() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(12)
        .frame(minWidth: 640, minHeight: 340)

        // 实时模式下，右缘跟着最新样本走（每来一条数据向前推进一次）。
        .onChange(of: logger.samples.last?.t) { newT in
            if followLive,
               let t = newT {
                endTime = t
            }
            refreshRightAxis()
        }
        .onAppear { refreshRightAxis() }
        .onChange(of: valueSeriesMask) { _ in refreshRightAxis() }
    }

    // MARK: - 图例

    private var legend: some View {
        HStack(spacing: 12) {
            legendToggle(L("chart.series.battery_pct"), $showBattery, batteryColor, value: { Double($0.batteryPercent) })
            legendToggle(L("chart.series.system_w"), $showSystemW, systemColor, value: { $0.systemWatts })
            legendToggle(L("chart.series.charging_w"), $showChargingW, chargeColor, value: { $0.chargingWatts })
            legendToggle(L("chart.series.cpu_pct"), $showCpu, cpuColor, value: { $0.cpuUsage * 100 })
            legendToggle(L("chart.series.ram_pct"), $showRam, ramColor, value: { $0.memoryUsage * 100 })
            legendToggle(L("chart.series.voltage"), $showVoltage, voltageColor, value: { $0.chargingVoltage })
            legendToggle(L("chart.series.current"), $showCurrent, currentColor, value: { $0.chargingCurrent })
            Spacer()
        }
        .font(.caption)
    }

    private func legendToggle(_ title: String, _ binding: Binding<Bool>, _ color: Color,
                              value: @escaping (PowerSample) -> Double) -> some View {
        Button {
            binding.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).foregroundColor(binding.wrappedValue ? .primary : .secondary)
                // 当前值：取最新样本，随 0.5s 采样实时刷新；隐藏系列时随名称一起变淡。
                Text(currentValueText(value))
                    .foregroundColor(binding.wrappedValue ? .primary : .secondary)
                    .fontWeight(.semibold)
            }
        }
        .buttonStyle(.plain)
    }

    /// 最新样本经映射后的展示文本（与悬浮提示同款 `fmtVal`）；无数据时显示 "--"。
    private func currentValueText(_ value: @escaping (PowerSample) -> Double) -> String {
        guard let s = logger.samples.last else { return L("common.placeholder") }
        return ChartAxes.fmtVal(value(s))
    }

    // 系列配色
    private var batteryColor: Color { Color(red: 0.16, green: 0.85, blue: 0.62) }
    private var systemColor: Color { Color(red: 0.95, green: 0.55, blue: 0.15) }
    private var chargeColor: Color { Color(red: 0.96, green: 0.82, blue: 0.30) }
    private var cpuColor: Color { Color(red: 0.25, green: 0.55, blue: 1.0) }
    private var ramColor: Color { Color(red: 0.75, green: 0.35, blue: 0.95) }
    private var voltageColor: Color { Color(red: 0.30, green: 0.80, blue: 0.95) }
    private var currentColor: Color { Color(red: 1.00, green: 0.45, blue: 0.42) }

    // MARK: - 图表主体

    private var chart: some View {
        GeometryReader { geo in
            let plot = ChartPlot(outer: geo.size, left: leftPad, right: rightPad, top: topPad, bottom: bottomPad)
            let draw = buildDraw(in: plot)
            let startE = endTime.timeIntervalSince1970 - timeRange
            let hover = hoverInfo(hoverX: hoverPoint?.x, plot: plot, startE: startE,
                                  timeRange: timeRange, samples: logger.samples, series: enabledSeries)

            ZStack {
                Canvas { ctx, size in
                    draw.render(context: ctx, size: size, timeRange: timeRange, hover: hover)
                }
                .background(Color.black.opacity(0.03))

                // 鼠标事件层：滚轮缩放/平移 + 悬停定位。
                ScrollWheelCatcher { dx, dy, option in
                    handleScroll(dx: dx, dy: dy, option: option, plot: plot)
                } onHover: { point in
                    hoverPoint = point
                }

                // 拖拽平移：基于手势起点的绝对跟随，1:1 跟随鼠标，不累加漂移。
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .updating($dragBase) { _, state, _ in
                            if state == nil {
                                state = DragBase(endTime: endTime)
                            }
                        }
                        .onChanged { value in
                            dragTranslation(value.translation, plot: plot)
                        })
            }
        }
    }

    // MARK: - 悬停

    /// 由鼠标 x 坐标定位最近的样本，生成竖线 + 数值浮层所需数据。
    private func hoverInfo(hoverX: CGFloat?, plot: ChartPlot, startE: Double,
                           timeRange: TimeInterval, samples: [PowerSample], series: [SeriesDef]) -> ChartHoverInfo? {
        guard let hx = hoverX, hx >= plot.minX, hx <= plot.maxX else { return nil }
        let targetE = startE + Double(hx - plot.minX) / plot.plotW * timeRange
        guard let s = ChartInteraction.nearestSample(upTo: targetE, in: samples, timestamp: { $0.t }) else { return nil }
        let x = plot.minX + (s.t.timeIntervalSince1970 - startE) / timeRange * plot.plotW
        let rows = series.map { ChartHoverInfo.Row(color: $0.color, title: $0.title, value: ChartAxes.fmtVal($0.dsp(s))) }
        return ChartHoverInfo(x: x, date: s.t, rows: rows)
    }

    /// 序列最近样本的定位与数值格式化已抽到 Charting（ChartInteraction / ChartAxes）。

    // MARK: - 系列定义

    /// 当前启用的系列。
    private var enabledSeries: [SeriesDef] {
        var list: [SeriesDef] = []
        if showBattery { list.append(SeriesDef(title: L("chart.series.battery_pct"), color: batteryColor, axis: .percent, dsp: { Double($0.batteryPercent) })) }
        if showCpu { list.append(SeriesDef(title: L("chart.series.cpu_pct"), color: cpuColor, axis: .percent, dsp: { $0.cpuUsage * 100 })) }
        if showRam { list.append(SeriesDef(title: L("chart.series.ram_pct"), color: ramColor, axis: .percent, dsp: { $0.memoryUsage * 100 })) }
        if showSystemW { list.append(SeriesDef(title: L("chart.series.system_w"), color: systemColor, axis: .value, dsp: { $0.systemWatts })) }
        if showChargingW { list.append(SeriesDef(title: L("chart.series.charging_w"), color: chargeColor, axis: .value, dsp: { $0.chargingWatts })) }
        if showVoltage { list.append(SeriesDef(title: L("chart.series.voltage"), color: voltageColor, axis: .value, dsp: { $0.chargingVoltage })) }
        if showCurrent { list.append(SeriesDef(title: L("chart.series.current"), color: currentColor, axis: .value, dsp: { $0.chargingCurrent })) }
        return list
    }

    /// 当前启用的真实值（右轴）系列位掩码；变化时需要重新适配右轴范围。
    private var valueSeriesMask: Int {
        (showSystemW ? 1 : 0) | (showChargingW ? 2 : 0) | (showVoltage ? 4 : 0) | (showCurrent ? 8 : 0)
    }

    private var summaryText: String {
        LP("chart.summary.samples", count: logger.samples.count, timeText(timeRange))
    }

    private func buildDraw(in plot: ChartPlot) -> ChartDraw {
        let startE = endTime.timeIntervalSince1970 - timeRange
        let endE = endTime.timeIntervalSince1970
        let (start, end) = visibleIndexRange()

        // 右轴（真实数值）范围由 refreshRightAxis() 维护：刻度取整 + 迟滞，避免随采样频繁跳动。
        // 曲线点由 ChartDraw 对 samples[sampleStart..<sampleEnd] 分桶平均生成，
        // 不在此复制可见数组，避免长时窗口（如 24h）每帧复制十几万样本。
        return ChartDraw(
            samples: logger.samples,
            sampleStart: start,
            sampleEnd: end,
            startE: startE,
            endE: endE,
            percentRange: percentRange,
            valueMin: rightMin,
            valueMax: rightMax,
            plot: plot,
            series: enabledSeries
        )
    }

    // MARK: - 右轴（真实数值）范围维护

    /// 当前可视时间窗口在 samples 中的索引区间（二分定位）。
    private func visibleIndexRange() -> (start: Int, end: Int) {
        let samples = logger.samples
        let startE = endTime.timeIntervalSince1970 - timeRange
        let endE = endTime.timeIntervalSince1970
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].t.timeIntervalSince1970 < startE { lo = mid + 1 } else { hi = mid }
        }
        let start = lo
        lo = start; hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].t.timeIntervalSince1970 <= endE { lo = mid + 1 } else { hi = mid }
        }
        return (start, lo)
    }

    /// 可视窗口内真实值系列（右轴）的实际最小 / 最大值。
    private func visibleValueBounds() -> (lo: Double, hi: Double) {
        let vals = enabledSeries.filter { $0.axis == .value }
        guard !vals.isEmpty else { return (.infinity, -.infinity) }
        let range = visibleIndexRange()
        guard range.end > range.start else { return (.infinity, -.infinity) }
        let samples = logger.samples
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        var i = range.start
        while i < range.end {
            let s = samples[i]
            for def in vals {
                let v = def.dsp(s)
                lo = min(lo, v); hi = max(hi, v)
            }
            i += 1
        }
        return lo.isFinite && hi.isFinite ? (lo, hi) : (.infinity, -.infinity)
    }

    /// 把原始数据范围换算成稳定的右轴目标范围：
    /// 1-2-5 刻度取整（nice 值）+ 15% 边距 + 至少 2.5 个刻度的最小跨度。
    private func niceViewport(_ lo: Double, _ hi: Double) -> (Double, Double) {
        var lo = lo, hi = hi
        if !(hi > lo) {
            // 恒定值（含全 0）：以 1 为跨度居中，避免噪声级轴范围。
            let c = lo
            lo = c - 0.5; hi = c + 0.5
            if lo < 0 { lo = 0 }
        }
        let pad = (hi - lo) * 0.15
        var a = lo - pad, b = hi + pad
        let step = ChartAxes.niceStep(b - a, target: 5)
        let minSpan = step * 2.5
        if b - a < minSpan {
            let m = (a + b) / 2
            a = m - minSpan / 2; b = m + minSpan / 2
        }
        a = floor(a / step) * step
        b = ceil(b / step) * step
        if a < 0 { a = 0 }
        if !(b > a) { b = a + step }
        return (a, b)
    }

    /// 数据 / 时间窗口变化后维护右轴范围。
    ///
    /// 两层稳定机制，保证「同一缩放 / 同一窗口下历史曲线绝对静止」：
    /// 1. 目标范围先取整到 nice 刻度，小幅噪声不改变结果（如 57.3→58.1W 都落在 0–80）；
    /// 2. 台阶式：数据超界立即扩张；数据最高点回落到轴上限 70% 以下时一次性跳到
    ///    新的 nice 范围（不做连续逼近）。固定窗口下目标范围不变 → 右轴恒定 → y 不漂移。
    private func refreshRightAxis() {
        guard autoRight else { return }
        let (lo, hi) = visibleValueBounds()
        guard lo.isFinite, hi.isFinite, hi >= lo else { return }
        let (tLo, tHi) = niceViewport(lo, hi)

        if !rightAxisInitialized {
            // 首次适配：直接跳到目标范围（从默认 0–100 一次到位）。
            rightMin = tLo
            rightMax = tHi
            rightAxisInitialized = true
            return
        }
        var a = rightMin, b = rightMax
        // 扩张：立即跟随。
        if tHi > b { b = tHi }
        if tLo < a { a = tLo }
        // 收缩：台阶式跳变（一次性到位，不连续逼近）。
        if b > tHi, hi < b - (b - a) * 0.3 { b = tHi }
        if a > 0, tLo > a, lo > a + (b - a) * 0.3 { a = tLo }
        rightMin = a
        rightMax = b
    }

    // MARK: - 交互

    private func dragTranslation(_ tr: CGSize, plot: ChartPlot) {
        // 拖拽只沿时间轴平移（基于手势起点 dragBase 的绝对 1:1 跟随）。
        // 右轴保持原始自动缩放比例，拖动不改变 Y 轴范围。
        guard let base = dragBase else { return }
        // 拖拽即进入"浏览历史"状态，停止实时跟随。
        followLive = false
        if let delta = ChartInteraction.panSeconds(dx: tr.width, plotWidth: plot.plotW, timeRange: timeRange) {
            endTime = clampEnd(base.endTime - delta)
        }
        refreshRightAxis()
    }

    private func handleScroll(dx: Double, dy: Double, option: Bool, plot: ChartPlot) {
        if option {
            // Option + 纵向滚动 → 缩放右轴（钳制单次幅度，避免一次滚轮跳变）。
            if dy != 0 {
                zoomRight(by: ChartInteraction.axesZoomFactor(dy: dy))
                autoRight = false
            }
            return
        }
        if abs(dx) > 0 {
            // 横向滚动 = 平移时间到历史，停止实时跟随。
            followLive = false
            if let delta = ChartInteraction.panSeconds(dx: dx, plotWidth: plot.plotW, timeRange: timeRange) {
                endTime = clampEnd(endTime - delta)
            }
        }
        if dy != 0 {
            // 纵向滚动 → 缩放时间窗口：右缘锚定（实时模式下保持贴最新），钳制单次缩放。
            zoomTime(by: ChartInteraction.timeZoomFactor(dy: dy))
        }
        refreshRightAxis()
    }

    private func zoomTime(by factor: Double) {
        // 右缘锚定：缩放只改变时间跨度，不移动右缘，实时模式始终保持贴最新。
        timeRange = ChartInteraction.zoomedRange(timeRange, by: factor, minView: minView, maxView: maxView)
    }

    private func zoomRight(by factor: Double) {
        var a = rightMin, b = rightMax
        let center = (a + b) / 2
        let span = b - a
        let clampedSpan = max(0.1, min(100_000, span / factor))
        a = center - clampedSpan / 2
        b = center + clampedSpan / 2
        rightMin = a; rightMax = b
    }

    /// 时间右缘上限（不越过当前时间 + 12s 采样余量），下限不早于最早样本。
    private func clampEnd(_ d: Date) -> Date {
        ChartInteraction.clampedEnd(d, now: Date(), earliest: logger.samples.first?.t)
    }

    private func fitToAll() {
        guard let t0 = logger.samples.first?.t,
              let t1 = logger.samples.last?.t else {
            endTime = Date(); timeRange = 30 * 60
            return
        }
        let span = t1.timeIntervalSince1970 - t0.timeIntervalSince1970
        var range = max(15, span)
        if range > maxView { range = maxView }
        timeRange = range
        endTime = Date()
        autoRight = true
        followLive = true
        rightAxisInitialized = false
        refreshRightAxis()
    }

    /// 确认后清空功率日志（内存 + 磁盘 CSV），历史不可恢复。
    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = L("alert.reset_history.title")
        alert.informativeText = L("alert.reset_history.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("common.reset"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        logger.reset()
        // 复位视图状态，回到空数据的默认视图。
        endTime = Date()
        timeRange = 30 * 60
        autoRight = true
        followLive = true
        rightAxisInitialized = false
    }

    /// 当前命中的窗口预设（未命中则返回 nil，视为「全部」选中）。
    private var activeWindowPreset: TimeInterval? {
        Self.windowPresets.first { $0 == timeRange }
    }

    /// 底部时间窗口按钮。参数是**文案键名**（不是最终文案），由 L() 取。
    private func windowPresetButton(_ key: String, _ seconds: TimeInterval) -> some View {
        let active = activeWindowPreset == seconds
        return Button(L(key)) { setWindow(seconds) }
            .buttonStyle(.plain)
            .font(.caption.weight(active ? .semibold : .regular))
            .foregroundColor(active ? Color.accentColor : .primary)
    }

    /// 切换到指定的时间窗口：回到实时跟随、复位右轴自适应并立即适配。
    private func setWindow(_ seconds: TimeInterval) {
        timeRange = min(max(seconds, minView), maxView)
        followLive = true
        // 右缘贴住最新样本（比 Date() 更精确，避免右缘超前于数据）。
        if let t = logger.samples.last?.t { endTime = t }
        autoRight = true
        rightAxisInitialized = false
        refreshRightAxis()
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        ChartAxes.timeText(seconds)
    }
}

// MARK: - 系列轴定义（文件级，供绘图对象复用）

/// 系列归属的纵轴：percent = 左轴 0–100%；value = 右轴真实数值。
private enum AxisKind { case percent, value }

/// 一个可绘制的系列定义。
private struct SeriesDef {
    let title: String
    let color: Color
    let axis: AxisKind
    let dsp: (PowerSample) -> Double
}

// MARK: - 实际绘图对象

private struct ChartDraw {
    let samples: [PowerSample]
    let sampleStart: Int
    let sampleEnd: Int
    let startE: Double
    let endE: Double
    let percentRange: ClosedRange<Double>
    let valueMin: Double
    let valueMax: Double
    let plot: ChartPlot
    let series: [SeriesDef]

    /// 一个带区：颜色 + 折线点。
    struct ActiveBand {
        let color: Color
        let points: [CGPoint]
    }

    var hasValueSeries: Bool { series.contains { $0.axis == .value } }

    /// 把可视样本按「绝对时间锚定桶」取平均（每桶一个点）后，分别按主/副轴换算成各系列的 (x, y) 点。
    ///
    /// 桶边界锚定在绝对时间网格上（`floor(t / bucketSpan)`），而非窗口相对位置：
    /// 窗口平移 / 实时滚动时，同一历史时刻始终落入同一个桶，桶内均值不变，
    /// 因此固定窗口下历史曲线绝对静止；滚动时曲线只整体平移、形状不波动。
    func buildBands() -> (percent: [ActiveBand], value: [ActiveBand]) {
        let plotW = plot.plotW, plotH = plot.plotH
        let minX = plot.minX, maxY = plot.maxY
        let span = max(1e-9, endE - startE)
        let bucketCount = max(1, Int(plotW))           // 每像素一桶
        let bucketSpan = span / Double(bucketCount)    // 每桶对应时间宽度
        let gridStart = Int(floor(startE / bucketSpan))  // 窗口左缘所在的绝对桶索引

        var percentBands: [ActiveBand] = []
        var valueBands: [ActiveBand] = []
        let pSpan = (percentRange.upperBound - percentRange.lowerBound)
        let vSpan = max(1e-9, valueMax - valueMin)

        for def in series {
            // 按绝对时间桶累加，桶内取均值（同一历史时刻永远落入同一桶）。
            var sums = [Double](repeating: 0, count: bucketCount)
            var counts = [Int](repeating: 0, count: bucketCount)
            var i = sampleStart
            while i < sampleEnd {
                let s = samples[i]
                let t = s.t.timeIntervalSince1970
                var b = Int(floor(t / bucketSpan)) - gridStart
                if b < 0 { b = 0 } else if b >= bucketCount { b = bucketCount - 1 }
                sums[b] += def.dsp(s)
                counts[b] += 1
                i += 1
            }
            var pts: [CGPoint] = []
            pts.reserveCapacity(bucketCount + 2)
            for b in 0..<bucketCount where counts[b] > 0 {
                // 桶中心用绝对时间换算 x：固定窗口下各桶的 x 恒定。
                let tCenter = (Double(gridStart + b) + 0.5) * bucketSpan
                let x = minX + (tCenter - startE) / span * plotW
                let v = sums[b] / Double(counts[b])
                let y: Double
                switch def.axis {
                case .percent:
                    let normalized = (v - percentRange.lowerBound) / pSpan
                    y = maxY - normalized * plotH
                case .value:
                    let normalized = (v - valueMin) / vSpan
                    y = maxY - normalized * plotH
                }
                pts.append(CGPoint(x: x, y: max(plot.minY, min(plot.maxY, y))))
            }
            if let first = pts.first { pts.insert(CGPoint(x: minX, y: first.y), at: 0) }
            if let last = pts.last { pts.append(CGPoint(x: plot.minX + plotW, y: last.y)) }
            switch def.axis {
            case .percent: percentBands.append(ActiveBand(color: def.color, points: pts))
            case .value: valueBands.append(ActiveBand(color: def.color, points: pts))
            }
        }
        return (percentBands, valueBands)
    }

    // MARK: 渲染

    func render(context: GraphicsContext, size: CGSize, timeRange: TimeInterval, hover: ChartHoverInfo?) {
        let plot = self.plot
        let bands = buildBands()

        // 裁剪到绘图区。
        var clip = Path()
        clip.addRect(CGRect(x: plot.minX, y: plot.minY, width: plot.plotW, height: plot.plotH))
        context.drawLayer { layer in
            layer.clip(to: clip)
            // 主轴（%）网格
            for y in ChartAxes.yTicks(percentRange.lowerBound, percentRange.upperBound) {
                let yy = percentY(y)
                var p = Path()
                p.move(to: CGPoint(x: plot.minX, y: yy))
                p.addLine(to: CGPoint(x: plot.maxX, y: yy))
                layer.stroke(p, with: .color(.gray.opacity(0.15)), lineWidth: 1)
            }
            // 时间网格
            for tick in timeTicks() {
                let xx = timeX(tick)
                if xx < plot.minX || xx > plot.maxX { continue }
                var p = Path()
                p.move(to: CGPoint(x: xx, y: plot.minY))
                p.addLine(to: CGPoint(x: xx, y: plot.maxY))
                layer.stroke(p, with: .color(.gray.opacity(0.12)), lineWidth: 1)
            }
            // 次轴（值）系列 → 副轴网格（若启用真实值系列）
            if hasValueSeries {
                for y in ChartAxes.yTicks(valueMin, valueMax) {
                    let yy = valueY(y)
                    var p = Path()
                    p.move(to: CGPoint(x: plot.minX, y: yy))
                    p.addLine(to: CGPoint(x: plot.maxX, y: yy))
                    layer.stroke(p, with: .color(.gray.opacity(0.10)), lineWidth: 1)
                }
            }
            // 折线（先百分比后真实值）
            for band in bands.percent { stroke(band, in: layer) }
            for band in bands.value { stroke(band, in: layer) }
        }

        // 坐标轴与标签（不裁剪）。
        axisLines(context: context)
        axisLabels(context: context, timeRange: timeRange)

        // 悬停：竖线 + 数值浮层。
        if let hover {
            ChartHover.draw(hover, in: context, plot: plot,
                            yTop: plot.minY, yBottom: plot.maxY,
                            span: endE - startE, lineOpacity: 0.55)
        }
    }

    private func stroke(_ band: ActiveBand, in layer: GraphicsContext) {
        ChartDrawing.strokePoints(band.points, color: band.color, in: layer)
    }

    private func axisLines(context ctx: GraphicsContext) {
        var p = Path()
        p.move(to: CGPoint(x: plot.minX, y: plot.minY))
        p.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        p.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        p.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        ctx.stroke(p, with: .color(.gray.opacity(0.35)), lineWidth: 1)
        // 右侧副轴刻度线
        var rp = Path()
        rp.move(to: CGPoint(x: plot.maxX, y: plot.minY))
        rp.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        ctx.stroke(rp, with: .color(.gray.opacity(0.22)), lineWidth: 1)
    }

    private func axisLabels(context ctx: GraphicsContext, timeRange: TimeInterval) {
        // 左轴 = 百分比（如果启用百分比系列）
        if !series.filter({ $0.axis == .percent }).isEmpty {
            for y in ChartAxes.yTicks(percentRange.lowerBound, percentRange.upperBound) {
                let text = Text(ChartAxes.formatY(y)).font(.system(size: 9)).foregroundColor(.gray)
                ctx.draw(text, at: CGPoint(x: plot.minX - 6, y: percentY(y)), anchor: .trailing)
            }
        }
        // 右轴 = 真实数值
        if hasValueSeries {
            for y in ChartAxes.yTicks(valueMin, valueMax) {
                let text = Text(ChartAxes.formatY(y)).font(.system(size: 9)).foregroundColor(.gray)
                ctx.draw(text, at: CGPoint(x: plot.maxX + 6, y: valueY(y)), anchor: .leading)
            }
        }
        // 底部时间
        let template = Self.xTemplate(for: timeRange)
        for tick in timeTicks() {
            let xx = timeX(tick)
            if xx < plot.minX || xx > plot.maxX { continue }
            let date = Date(timeIntervalSince1970: tick)
            let text = Text(LocalizedFormat.date(date, template: template))
                .font(.system(size: 9)).foregroundColor(.gray)
            ctx.draw(text, at: CGPoint(x: xx, y: plot.maxY + 12), anchor: .top)
        }
    }

    // MARK: 坐标转换

    private func timeX(_ epoch: Double) -> Double {
        plot.minX + (epoch - startE) / (endE - startE) * plot.plotW
    }

    private func percentY(_ v: Double) -> Double {
        plot.maxY - (v - percentRange.lowerBound) / (percentRange.upperBound - percentRange.lowerBound) * plot.plotH
    }

    private func valueY(_ v: Double) -> Double {
        plot.maxY - (v - valueMin) / (valueMax - valueMin) * plot.plotH
    }

    // MARK: 刻度

    private func timeTicks() -> [Double] {
        let span = endE - startE
        let step = ChartAxes.niceTimeStep(span, minimumStep: 1)
        var out: [Double] = []
        var v = ceil(startE / step) * step
        while v <= endE + step {
            out.append(v)
            v += step
        }
        return out
    }

    /// 时间轴刻度用的日期字段模板（由系统按当前区域解析，12/24 小时制与日期顺序自动适配）。
    ///
    /// 原先直接写死 `dateFormat`，在 12 小时制区域会得到 24 小时制文本。
    /// ⚠️ `MMdj`（月日 + 时分）在 en_US 下比中文宽约 40%，长跨度窗口的刻度标签需真机核对密度。
    private static func xTemplate(for timeRange: TimeInterval) -> String {
        if timeRange <= 3600 { return "jms" }
        if timeRange <= 86400 { return "jm" }
        return "MMdj"
    }
}

// 刻度步长 niceStep / niceTimeStep 已抽到 Charting/ChartAxes.swift（历史图与电池健康图共用）。