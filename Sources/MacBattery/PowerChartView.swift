import SwiftUI
import AppKit

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
    /// 右轴上一次适配时间，用于迟滞收缩按时间衰减（与调用频率无关）。
    @State private var lastAxisUpdate = Date.distantPast

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
                Text("左轴：%  ·  右轴：W / V / A")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                // 时间窗口快捷切换：5m / 30m / 1h / 24h / 全部（当前选中项高亮）。
                windowPresetButton("5m", Self.windowPresets[0])
                windowPresetButton("30m", Self.windowPresets[1])
                windowPresetButton("1h", Self.windowPresets[2])
                windowPresetButton("24h", Self.windowPresets[3])
                Button("全部") { fitToAll() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(activeWindowPreset == nil ? .semibold : .regular))
                    .foregroundColor(activeWindowPreset == nil ? Color.accentColor : .primary)
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
            legendToggle("电池%", $showBattery, batteryColor)
            legendToggle("整机 W", $showSystemW, systemColor)
            legendToggle("充电 W", $showChargingW, chargeColor)
            legendToggle("CPU%", $showCpu, cpuColor)
            legendToggle("RAM%", $showRam, ramColor)
            legendToggle("电压 V", $showVoltage, voltageColor)
            legendToggle("电流 A", $showCurrent, currentColor)
            Spacer()
        }
        .font(.caption)
    }

    private func legendToggle(_ title: String, _ binding: Binding<Bool>, _ color: Color) -> some View {
        Button {
            binding.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).foregroundColor(binding.wrappedValue ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
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
            let plot = PlotRect(outer: geo.size, left: leftPad, right: rightPad, top: topPad, bottom: bottomPad)
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
    private func hoverInfo(hoverX: CGFloat?, plot: PlotRect, startE: Double,
                           timeRange: TimeInterval, samples: [PowerSample], series: [SeriesDef]) -> HoverInfo? {
        guard let hx = hoverX, hx >= plot.minX, hx <= plot.maxX else { return nil }
        let targetE = startE + Double(hx - plot.minX) / plot.plotW * timeRange
        guard let s = nearestSample(upTo: targetE, in: samples) else { return nil }
        let x = plot.minX + CGFloat((s.t.timeIntervalSince1970 - startE) / timeRange) * plot.plotW
        let rows = series.map { HoverInfo.Row(color: $0.color, title: $0.title, value: fmtVal($0.dsp(s))) }
        return HoverInfo(x: x, date: s.t, rows: rows)
    }

    /// 序列中时间不超过 target 的最近一条。
    private func nearestSample(upTo target: Double, in arr: [PowerSample]) -> PowerSample? {
        guard !arr.isEmpty else { return nil }
        var lo = 0, hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid].t.timeIntervalSince1970 <= target { lo = mid + 1 } else { hi = mid }
        }
        let idx = lo - 1
        return idx >= 0 ? arr[idx] : nil
    }

    private func fmtVal(_ v: Double) -> String {
        if v.magnitude >= 100 { return String(format: "%.0f", v) }
        if v == v.rounded() { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }

    // MARK: - 系列定义

    /// 当前启用的系列。
    private var enabledSeries: [SeriesDef] {
        var list: [SeriesDef] = []
        if showBattery { list.append(SeriesDef(title: "电池%", color: batteryColor, axis: .percent, dsp: { Double($0.batteryPercent) })) }
        if showCpu { list.append(SeriesDef(title: "CPU%", color: cpuColor, axis: .percent, dsp: { $0.cpuUsage * 100 })) }
        if showRam { list.append(SeriesDef(title: "RAM%", color: ramColor, axis: .percent, dsp: { $0.memoryUsage * 100 })) }
        if showSystemW { list.append(SeriesDef(title: "整机 W", color: systemColor, axis: .value, dsp: { $0.systemWatts })) }
        if showChargingW { list.append(SeriesDef(title: "充电 W", color: chargeColor, axis: .value, dsp: { $0.chargingWatts })) }
        if showVoltage { list.append(SeriesDef(title: "电压 V", color: voltageColor, axis: .value, dsp: { $0.chargingVoltage })) }
        if showCurrent { list.append(SeriesDef(title: "电流 A", color: currentColor, axis: .value, dsp: { $0.chargingCurrent })) }
        return list
    }

    /// 当前启用的真实值（右轴）系列位掩码；变化时需要重新适配右轴范围。
    private var valueSeriesMask: Int {
        (showSystemW ? 1 : 0) | (showChargingW ? 2 : 0) | (showVoltage ? 4 : 0) | (showCurrent ? 8 : 0)
    }

    private var summaryText: String {
        "样本 \(logger.samples.count) 个 · 查看最近 " + timeText(timeRange)
    }

    private func buildDraw(in plot: PlotRect) -> ChartDraw {
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
        let step = niceStep(b - a, target: 5)
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
    /// 两层稳定机制，避免随 0.5s 一次采样频繁跳动：
    /// 1. 目标范围先取整到 nice 刻度，小幅噪声不改变结果（如 57.3→58.1W 都落在 0–80）；
    /// 2. 迟滞：数据超界立即扩张；数据最高点回落到轴上限 70% 以下时才按时间缓慢收缩
    ///    （每秒收敛约 20%），短暂尖峰不会让整个纵轴来回拉扯。
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
            lastAxisUpdate = Date()
            return
        }
        var a = rightMin, b = rightMax
        // 扩张：立即跟随。
        if tHi > b { b = tHi }
        if tLo < a { a = tLo }
        // 收缩：迟滞 + 按时间衰减（每秒收敛 20%，与调用频率无关，拖动时也平滑）。
        let dt = min(3.0, Date().timeIntervalSince(lastAxisUpdate))
        let k = 1 - pow(0.8, dt)
        if b > tHi, hi < b - (b - a) * 0.3 {
            b = max(tHi, b - (b - tHi) * k)
        }
        if a > 0, tLo > a, lo > a + (b - a) * 0.3 {
            a = min(tLo, a + (tLo - a) * k)
        }
        rightMin = a
        rightMax = b
        lastAxisUpdate = Date()
    }

    // MARK: - 交互

    private func dragTranslation(_ tr: CGSize, plot: PlotRect) {
        // 拖拽只沿时间轴平移（基于手势起点 dragBase 的绝对 1:1 跟随）。
        // 右轴保持原始自动缩放比例，拖动不改变 Y 轴范围。
        guard let base = dragBase else { return }
        // 拖拽即进入"浏览历史"状态，停止实时跟随。
        followLive = false
        let ptsPerSec = plot.plotW / timeRange
        if ptsPerSec > 0 {
            endTime = clampEnd(base.endTime - tr.width / ptsPerSec)
        }
        refreshRightAxis()
    }

    private func handleScroll(dx: Double, dy: Double, option: Bool, plot: PlotRect) {
        if option {
            // Option + 纵向滚动 → 缩放右轴（钳制单次幅度，避免一次滚轮跳变）。
            if dy != 0 {
                zoomRight(by: bounded(exp(Double(-dy) * 0.015), 0.86, 1.16))
                autoRight = false
            }
            return
        }
        if abs(dx) > 0 {
            // 横向滚动 = 平移时间到历史，停止实时跟随。
            followLive = false
            let ptsPerSec = plot.plotW / timeRange
            if ptsPerSec > 0 {
                endTime = clampEnd(endTime - dx / ptsPerSec)
            }
        }
        if dy != 0 {
            // 纵向滚动 → 缩放时间窗口：右缘锚定（实时模式下保持贴最新），钳制单次缩放。
            zoomTime(by: bounded(exp(Double(-dy) * 0.02), 0.84, 1.19))
        }
        refreshRightAxis()
    }

    private func bounded(_ f: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(f, lo), hi)
    }

    private func zoomTime(by factor: Double) {
        var newRange = timeRange / factor
        if newRange > maxView { newRange = maxView }
        if newRange < minView { newRange = minView }
        // 右缘锚定：缩放只改变时间跨度，不移动右缘，实时模式始终保持贴最新。
        timeRange = newRange
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
        let now = Date().addingTimeInterval(12)
        let earliest = logger.samples.first?.t
        if d > now { return now }
        if let e = earliest, d < e.addingTimeInterval(20) { return e.addingTimeInterval(20) }
        return d
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

    /// 当前命中的窗口预设（未命中则返回 nil，视为「全部」选中）。
    private var activeWindowPreset: TimeInterval? {
        Self.windowPresets.first { $0 == timeRange }
    }

    /// 底部时间窗口按钮。
    private func windowPresetButton(_ title: String, _ seconds: TimeInterval) -> some View {
        let active = activeWindowPreset == seconds
        return Button(title) { setWindow(seconds) }
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
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟" }
        if seconds < 86400 { return String(format: "%.1f 小时", seconds / 3600) }
        return String(format: "%.1f 天", seconds / 86400)
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

/// 悬停浮层数据：竖线位置 + 该时刻各系列取值。
private struct HoverInfo {
    let x: CGFloat
    let date: Date
    let rows: [Row]

    struct Row {
        let color: Color
        let title: String
        let value: String
    }
}

// MARK: - 绘制矩形区域

private struct PlotRect {
    let outer: CGSize
    let left, right, top, bottom: Double

    var plotW: Double { max(10, outer.width - left - right) }
    var plotH: Double { max(10, outer.height - top - bottom) }

    var minX: Double { left }
    var minY: Double { top }
    var maxX: Double { left + plotW }
    var maxY: Double { top + plotH }

    init(outer: CGSize, left: Double, right: Double, top: Double, bottom: Double) {
        self.outer = outer
        self.left = left; self.right = right; self.top = top; self.bottom = bottom
    }
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
    let plot: PlotRect
    let series: [SeriesDef]

    /// 一个带区：颜色 + 折线点。
    struct ActiveBand {
        let color: Color
        let points: [CGPoint]
    }

    var hasValueSeries: Bool { series.contains { $0.axis == .value } }

    /// 把可视样本按像素分桶取平均（每桶一个点）后，分别按主/副轴换算成各系列的 (x, y) 点。
    /// 相比逐点抽稀，分桶平均对 CPU / 整机功耗这类 0.5s 高频抖动的数据更稳定：
    /// 长时间窗下每个像素代表一段时间窗的均值，毛刺被抹平、趋势不丢失。
    func buildBands() -> (percent: [ActiveBand], value: [ActiveBand]) {
        let plotW = plot.plotW, plotH = plot.plotH
        let minX = plot.minX, maxY = plot.maxY
        let span = max(1e-9, endE - startE)
        let bucketCount = max(1, Int(plotW))   // 每像素一桶

        var percentBands: [ActiveBand] = []
        var valueBands: [ActiveBand] = []
        let pSpan = (percentRange.upperBound - percentRange.lowerBound)
        let vSpan = max(1e-9, valueMax - valueMin)

        for def in series {
            // 先按时间把每个样本归入对应像素桶并累加，桶内取均值。
            var sums = [Double](repeating: 0, count: bucketCount)
            var counts = [Int](repeating: 0, count: bucketCount)
            var i = sampleStart
            while i < sampleEnd {
                let s = samples[i]
                let frac = (s.t.timeIntervalSince1970 - startE) / span
                var b = Int(frac * Double(bucketCount))
                if b < 0 { b = 0 } else if b >= bucketCount { b = bucketCount - 1 }
                sums[b] += def.dsp(s)
                counts[b] += 1
                i += 1
            }
            var pts: [CGPoint] = []
            pts.reserveCapacity(bucketCount + 2)
            for b in 0..<bucketCount where counts[b] > 0 {
                let x = minX + (Double(b) + 0.5) / Double(bucketCount) * plotW
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

    func render(context: GraphicsContext, size: CGSize, timeRange: TimeInterval, hover: HoverInfo?) {
        let plot = self.plot
        let bands = buildBands()

        // 裁剪到绘图区。
        var clip = Path()
        clip.addRect(CGRect(x: plot.minX, y: plot.minY, width: plot.plotW, height: plot.plotH))
        context.drawLayer { layer in
            layer.clip(to: clip)
            // 主轴（%）网格
            for y in yTicks(percentRange.lowerBound, percentRange.upperBound) {
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
                for y in yTicks(valueMin, valueMax) {
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
            drawHover(hover, in: context, plot: plot)
        }
    }

    /// 绘制悬停竖线 + 该时刻数值浮层。
    private func drawHover(_ hover: HoverInfo, in ctx: GraphicsContext, plot: PlotRect) {
        let x = CGFloat(hover.x)
        guard x >= plot.minX, x <= plot.maxX else { return }

        // 竖线
        var vp = Path()
        vp.move(to: CGPoint(x: x, y: plot.minY))
        vp.addLine(to: CGPoint(x: x, y: plot.maxY))
        ctx.stroke(vp, with: .color(.white.opacity(0.55)), lineWidth: 1)

        // 浮层放竖线偏向空白一侧。
        let goRight = x < plot.minX + plot.plotW / 2
        let anchor: UnitPoint = goRight ? .leading : .trailing
        let bx = goRight ? x + 10 : x - 10
        let formatter = DateFormatter()
        let span = endE - startE
        if span >= 86400 { formatter.dateFormat = "MM-dd HH:mm" }
        else if span >= 3600 { formatter.dateFormat = "HH:mm" }
        else { formatter.dateFormat = "HH:mm:ss" }
        let timeText = Text(formatter.string(from: hover.date))
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
        ctx.draw(timeText, at: CGPoint(x: bx, y: plot.minY + 8), anchor: anchor)

        var yy = plot.minY + 26
        for row in hover.rows {
            let line = Text("\(row.title)  \(row.value)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(row.color)
            ctx.draw(line, at: CGPoint(x: bx, y: yy), anchor: anchor)
            yy += 15
        }
    }

    private func stroke(_ band: ActiveBand, in layer: GraphicsContext) {
        guard band.points.count >= 2 else { return }
        var path = Path()
        path.move(to: band.points[0])
        for pt in band.points.dropFirst() { path.addLine(to: pt) }
        layer.stroke(path, with: .color(band.color.opacity(0.9)),
                     style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
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
            for y in yTicks(percentRange.lowerBound, percentRange.upperBound) {
                let text = Text(formatY(y)).font(.system(size: 9)).foregroundColor(.gray)
                ctx.draw(text, at: CGPoint(x: plot.minX - 6, y: percentY(y)), anchor: .trailing)
            }
        }
        // 右轴 = 真实数值
        if hasValueSeries {
            for y in yTicks(valueMin, valueMax) {
                let text = Text(formatY(y)).font(.system(size: 9)).foregroundColor(.gray)
                ctx.draw(text, at: CGPoint(x: plot.maxX + 6, y: valueY(y)), anchor: .leading)
            }
        }
        // 底部时间
        let formatter = Self.xFormatter(for: timeRange)
        for tick in timeTicks() {
            let xx = timeX(tick)
            if xx < plot.minX || xx > plot.maxX { continue }
            let date = Date(timeIntervalSince1970: tick)
            let text = Text(formatter.string(from: date)).font(.system(size: 9)).foregroundColor(.gray)
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

    private func yTicks(_ minV: Double, _ maxV: Double) -> [Double] {
        let span = maxV - minV
        guard span > 0 else { return [] }
        let step = niceStep(span, target: 5)
        var out: [Double] = []
        var v = ceil(minV / step) * step
        while v <= maxV + 1e-9 {
            out.append(v)
            v += step
        }
        return out
    }

    private func timeTicks() -> [Double] {
        let span = endE - startE
        let step = niceTimeStep(span)
        var out: [Double] = []
        var v = ceil(startE / step) * step
        while v <= endE + step {
            out.append(v)
            v += step
        }
        return out
    }

    private func niceTimeStep(_ span: Double) -> Double {
        let candidates: [Double] = [1, 2, 5, 10, 15, 30,
                                    60, 120, 300, 600, 900, 1800,
                                    3600, 7200, 14400, 21600, 36000, 43200, 86400]
        let target = span / 6
        for c in candidates where c >= target { return c }
        return candidates.last ?? 86400
    }

    private func formatY(_ v: Double) -> String {
        if abs(v - v.rounded()) < 1e-6 || v.magnitude >= 100 { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }

    private static func xFormatter(for timeRange: TimeInterval) -> DateFormatter {
        let f = DateFormatter()
        if timeRange <= 3600 { f.dateFormat = "HH:mm:ss" }
        else if timeRange <= 86400 { f.dateFormat = "HH:mm" }
        else { f.dateFormat = "MM-dd HH:mm" }
        return f
    }
}

// MARK: - 滚轮捕获（NSView 桥接）

/// 捕获滚动 + 鼠标悬停事件并回调给 SwiftUI。
/// dx/dy 为带符号滚动位移，option 表示是否按住 Option；onHover 回传鼠标位置（nil 表示离开）。
struct ScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (Double, Double, Bool) -> Void
    var onHover: (CGPoint?) -> Void

    func makeNSView(context: Context) -> ScrollCatcherView {
        let v = ScrollCatcherView()
        v.onScroll = onScroll
        v.onHover = onHover
        v.allowedTouchTypes = [.direct, .indirect]
        return v
    }

    func updateNSView(_ nsView: ScrollCatcherView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onHover = onHover
    }
}

final class ScrollCatcherView: NSView {
    var onScroll: ((Double, Double, Bool) -> Void)?
    var onHover: ((CGPoint?) -> Void)?
    private var tracking: NSTrackingArea?

    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let option = event.modifierFlags.contains(.option)
        if dx != 0 || dy != 0 {
            onScroll?(dx, dy, option)
        }
        // 已消费，不冒泡。
    }

    // MARK: 悬停跟踪

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }
}

// MARK: - 刻度步长（文件级共享）

/// 单调的 1-2-5 刻度步长：span 增大时步长只增不减，保证轴范围与刻度对齐、稳定。
/// 右轴范围取整（niceViewport）与刻度绘制（yTicks）共用同一实现。
private func niceStep(_ span: Double, target: Int) -> Double {
    guard span > 0 else { return 1 }
    let raw = span / Double(max(1, target))
    let mag = pow(10, floor(log10(raw)))
    let residual = raw / mag
    let step: Double
    if residual < 1 { step = 1 }
    else if residual < 2 { step = 2 }
    else if residual < 2.5 { step = 2.5 }
    else if residual < 5 { step = 5 }
    else { step = 10 }
    return step * mag
}