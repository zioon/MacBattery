import SwiftUI
import AppKit
import MacBatteryCore

/// 电池数据分析面板：把功率日志里**时间敏感、值得长期留痕**的字段集中呈现。
///
/// 与历史图表（PowerChartView）的分工：
/// - 历史图表关注整机功耗 / CPU / 内存等运行负载；
/// - 本面板关注电池本身：温度、剩余时间估算、当前容量，以及健康度 / 循环次数等慢变指标。
///
/// 数据来源：
/// - 温度 / 剩余时间 / 容量 / 充满状态 → `PowerLogger.samples`（0.5s 采样、门控落盘、可回填历史）；
/// - 健康度 / 循环次数 → `BatteryHealthLogger`（独立 CSV，变化极慢）。
///
/// 交互（与历史图表保持一致）：
/// - 横向滚动 / 拖拽：左右平移时间；纵向滚动：缩放时间窗；
/// - 「全部」：回到全部数据并恢复实时跟随。
struct BatteryAnalysisView: View {

    @ObservedObject var logger: PowerLogger
    @ObservedObject var healthLogger: BatteryHealthLogger
    /// 语言变化时驱动本视图重绘（不必额外注入参数，直接观察共享实例）。
    @ObservedObject private var localization: LocalizationManager

    // MARK: 可见范围状态

    @State private var timeRange: TimeInterval = 6 * 3600
    @State private var endTime: Date = Date()
    @State private var followLive = true

    /// 视窗左缘已越过内存里的最早样本：等待更早历史补入后继续补载（分页的续读信号）。
    @State private var awaitingOlderHistory = false

    /// 鼠标在图表内的悬停位置（相对画布全尺寸，y 向下，nil 表示已离开）。
    @State private var hoverPoint: CGPoint?

    @GestureState private var dragBase: DragBase?
    private struct DragBase { let endTime: Date }

    private var minView: TimeInterval { 10 * 60 }
    private var maxView: TimeInterval { 30 * 86400 }

    /// 快捷时间范围预设（秒）：1 小时 / 6 小时 / 24 小时 / 7 天。
    static let windowPresets: [TimeInterval] = [3600, 6 * 3600, 86400, 7 * 86400]
    private static let presetKeys = ["analysis.window.1h", "analysis.window.6h",
                                     "analysis.window.24h", "analysis.window.7d"]

    init(logger: PowerLogger, healthLogger: BatteryHealthLogger) {
        self.logger = logger
        self.healthLogger = healthLogger
        self.localization = LocalizationManager.shared
        _endTime = State(initialValue: Date())
    }

    var body: some View {
        VStack(spacing: 8) {
            metricBar
            chartArea
            presetBar
        }
        .padding(12)
        .frame(minWidth: 620, minHeight: 380)

        // 实时跟随：来一条新样本就前推右缘。
        .onChange(of: logger.samples.last?.t) { t in
            if followLive, let t = t {
                endTime = t
            }
        }
        // 更早历史补载完成（内存最早样本前移）：若视窗左缘仍超出，继续补下一页。
        .onChange(of: logger.samples.first?.t) { _ in
            if awaitingOlderHistory { maybeLoadOlderHistory() }
        }
        // 已回溯到文件头：把越界的时间右缘收回，避免停在无数据的空白区。
        .onChange(of: logger.reachedHistoryStart) { _ in
            endTime = clampEnd(endTime)
        }
    }

    // MARK: - 当前指标

    /// 一张当前值卡片。
    private struct Metric {
        let title: String
        let value: String
        let color: Color
    }

    private var metricBar: some View {
        let all = currentMetrics
        let firstRow = Array(all.prefix(4))
        let secondRow = Array(all.dropFirst(4))
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    metricTile(firstRow[i])
                }
            }
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    metricTile(secondRow[i])
                }
            }
        }
    }

    private func metricTile(_ m: Metric) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(m.title)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(m.value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(m.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(m.color.opacity(0.09)))
    }

    /// 八张卡片的取值。最新一条功率采样 + 最新一条健康采样即可覆盖全部。
    private var currentMetrics: [Metric] {
        let s = logger.samples.last
        let h = healthLogger.samples.last

        let temperature: String
        if let c = s?.temperatureCelsius {
            temperature = L("analysis.temperature.value", LocalizedFormat.number(c, decimals: 1))
        } else {
            temperature = L("common.placeholder")
        }

        let capacity: String
        if let s = s, let mAh = s.currentCapacity {
            capacity = L("analysis.capacity.value", mAh, s.batteryPercent)
        } else {
            capacity = L("common.placeholder")
        }

        let health: String
        if let h = h {
            health = L("health.unit.pct", LocalizedFormat.number(h.healthPercent, decimals: 1))
        } else {
            health = L("common.placeholder")
        }

        let cycles: String
        if let h = h {
            cycles = LP("health.unit.cycles", count: h.cycleCount)
        } else {
            cycles = L("common.placeholder")
        }

        let voltage = s.map { L("analysis.voltage.value", LocalizedFormat.number($0.chargingVoltage, decimals: 2)) }
            ?? L("common.placeholder")
        let current = s.map { L("analysis.current.value", LocalizedFormat.number($0.chargingCurrent, decimals: 2)) }
            ?? L("common.placeholder")

        return [
            Metric(title: L("analysis.temperature"), value: temperature,
                   color: AnalysisPalette.temperature),
            Metric(title: L("analysis.remaining"), value: remainingText(s),
                   color: AnalysisPalette.remaining),
            Metric(title: L("analysis.capacity"), value: capacity,
                   color: AnalysisPalette.capacity),
            Metric(title: L("analysis.power_state"), value: stateText(s),
                   color: AnalysisPalette.state),
            Metric(title: L("analysis.health"), value: health,
                   color: AnalysisPalette.health),
            Metric(title: L("analysis.cycles"), value: cycles,
                   color: AnalysisPalette.cycles),
            Metric(title: L("analysis.voltage"), value: voltage,
                   color: AnalysisPalette.voltage),
            Metric(title: L("analysis.current"), value: current,
                   color: AnalysisPalette.current)
        ]
    }

    /// 剩余时间：保留系统哨兵语义（-1 估算中 / -2 接通电源），其余按分钟转时长文本。
    private func remainingText(_ s: PowerSample?) -> String {
        guard let m = s?.remainingMinutes else { return L("common.placeholder") }
        switch m {
        case -2: return L("analysis.remaining.on_ac")
        case -1: return L("analysis.remaining.estimating")
        default: return m <= 0 ? L("common.placeholder") : ChartAxes.timeText(Double(m) * 60)
        }
    }

    /// 电源状态：充电中 / 已充满 / 已接电源 / 电池供电 / 未知。
    ///
    /// 顺序不能颠倒：正在充电时 `fullyCharged` 必然为 false，但接电未充电既可能是
    /// 「刚充满」也可能是「限充保持」，靠 `fullyCharged` 才能区分。
    private func stateText(_ s: PowerSample?) -> String {
        guard let s = s else { return L("analysis.state.unknown") }
        if s.isCharging { return L("analysis.state.charging") }
        if s.fullyCharged == true { return L("analysis.state.full") }
        switch s.externalPower {
        case .some(true): return L("analysis.state.plugged")
        case .some(false): return L("analysis.state.battery")
        case .none: return L("analysis.state.unknown")
        }
    }

    // MARK: - 底部时间窗工具条

    private var presetBar: some View {
        HStack(spacing: 10) {
            Text(summaryText)
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            Text(L("analysis.axis_hint"))
                .font(.caption2)
                .foregroundColor(.secondary)
            ForEach(0..<Self.windowPresets.count, id: \.self) { index in
                windowPresetButton(Self.presetKeys[index], Self.windowPresets[index])
            }
            Button(L("common.all")) { fitToAll() }
                .buttonStyle(.plain)
                .font(.caption.weight(activeWindowPreset == nil ? .semibold : .regular))
                .foregroundColor(activeWindowPreset == nil ? Color.accentColor : .primary)
        }
    }

    private var summaryText: String {
        LP("chart.summary.samples", count: logger.samples.count, ChartAxes.timeText(timeRange))
    }

    private var activeWindowPreset: TimeInterval? {
        Self.windowPresets.first { $0 == timeRange }
    }

    private func windowPresetButton(_ key: String, _ seconds: TimeInterval) -> some View {
        let active = activeWindowPreset == seconds
        return Button(L(key)) { setWindow(seconds) }
            .buttonStyle(.plain)
            .font(.caption.weight(active ? .semibold : .regular))
            .foregroundColor(active ? Color.accentColor : .primary)
    }

    private func setWindow(_ seconds: TimeInterval) {
        timeRange = min(max(seconds, minView), maxView)
        followLive = true
        if let t = logger.samples.last?.t { endTime = t }
    }

    // MARK: - 图表区域

    private var chartArea: some View {
        GeometryReader { geo in
            let plot = ChartPlot(outer: geo.size, left: 54, right: 54, top: 8, bottom: 26)
            let draw = buildDraw(plot)
            let hover = hoverInfo(hoverX: hoverPoint?.x, plot: plot)

            ZStack {
                Canvas { ctx, _ in draw.render(context: ctx, hover: hover) }
                    .background(Color.black.opacity(0.03))

                // 滚轮：横向平移 / 纵向缩放时间窗；悬停定位。
                ScrollWheelCatcher { dx, dy, _ in
                    handleScroll(dx: dx, dy: dy, plot: plot)
                } onHover: { point in
                    hoverPoint = point
                }

                // 拖拽平移。
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .updating($dragBase) { _, state, _ in
                            if state == nil { state = DragBase(endTime: endTime) }
                        }
                        .onChanged { value in
                            dragTranslation(value.translation, plot: plot)
                        })
            }
        }
    }

    private func buildDraw(_ plot: ChartPlot) -> AnalysisDraw {
        let startE = endTime.timeIntervalSince1970 - timeRange
        let endE = endTime.timeIntervalSince1970
        let samples = logger.samples

        // 二分定位可见窗口，避免每帧遍历整个内存缓冲。
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
        let end = lo
        let visible = start < end ? Array(samples[start..<end]) : []

        let tempRange = autoRange(visible.compactMap { $0.temperatureCelsius }) ?? (20...40)
        let capRange = autoRange(visible.compactMap { $0.currentCapacity }.map { Double($0) },
                                 floorAtZero: true) ?? (0...5000)
        let remainRange = autoRange(visible.compactMap { sample -> Double? in
            guard let m = sample.remainingMinutes, m >= 0 else { return nil }
            return Double(m)
        }, floorAtZero: true) ?? (0...300)

        return AnalysisDraw(visibleSamples: visible,
                            startE: startE, endE: endE,
                            plot: plot,
                            tempRange: tempRange,
                            capRange: capRange,
                            remainRange: remainRange)
    }

    /// 自适应 y 范围：带 10% 内边距、最小跨度 1；`floorAtZero` 用于容量 / 时长这类非负量。
    private func autoRange(_ values: [Double], floorAtZero: Bool = false) -> ClosedRange<Double>? {
        guard let lo0 = values.min(), let hi0 = values.max(),
              lo0.isFinite, hi0.isFinite else { return nil }
        var lo = lo0, hi = hi0
        if hi - lo < 1 { let mid = (lo + hi) / 2; lo = mid - 1; hi = mid + 1 }
        let pad = (hi - lo) * 0.10
        var a = lo - pad, b = hi + pad
        if floorAtZero { a = max(0, a) }
        if b - a < 2 { let mid = (a + b) / 2; a = mid - 1; b = mid + 1 }
        if floorAtZero { a = max(0, a) }
        return a...b
    }

    // MARK: - 悬停

    private func hoverInfo(hoverX: CGFloat?, plot: ChartPlot) -> ChartHoverInfo? {
        guard let hx = hoverX, hx >= plot.minX, hx <= plot.maxX else { return nil }
        let startE = endTime.timeIntervalSince1970 - timeRange
        let targetE = startE + Double(hx - plot.minX) / plot.plotW * timeRange
        guard let s = ChartInteraction.nearestSample(upTo: targetE,
                                                     in: logger.samples,
                                                     timestamp: { $0.t }) else { return nil }
        let x = plot.minX + (s.t.timeIntervalSince1970 - startE) / timeRange * plot.plotW

        var rows: [ChartHoverInfo.Row] = [
            ChartHoverInfo.Row(color: AnalysisPalette.state,
                               title: L("analysis.power_state"),
                               value: stateText(s))
        ]
        if let c = s.temperatureCelsius {
            rows.append(ChartHoverInfo.Row(color: AnalysisPalette.temperature,
                                           title: L("analysis.temperature"),
                                           value: L("analysis.temperature.value",
                                                    LocalizedFormat.number(c, decimals: 1))))
        }
        if let mAh = s.currentCapacity {
            rows.append(ChartHoverInfo.Row(color: AnalysisPalette.capacity,
                                           title: L("analysis.capacity"),
                                           value: L("analysis.capacity.value", mAh, s.batteryPercent)))
        }
        if s.remainingMinutes != nil {
            rows.append(ChartHoverInfo.Row(color: AnalysisPalette.remaining,
                                           title: L("analysis.remaining"),
                                           value: remainingText(s)))
        }
        return ChartHoverInfo(x: x, date: s.t, rows: rows)
    }

    // MARK: - 交互

    private func dragTranslation(_ tr: CGSize, plot: ChartPlot) {
        guard let base = dragBase else { return }
        followLive = false
        if let delta = ChartInteraction.panSeconds(dx: tr.width, plotWidth: plot.plotW, timeRange: timeRange) {
            endTime = clampEnd(base.endTime - delta)
        }
        maybeLoadOlderHistory()
    }

    private func handleScroll(dx: Double, dy: Double, plot: ChartPlot) {
        if abs(dx) > 0 {
            followLive = false
            if let delta = ChartInteraction.panSeconds(dx: dx, plotWidth: plot.plotW, timeRange: timeRange) {
                endTime = clampEnd(endTime - delta)
            }
        }
        if dy != 0 {
            timeRange = ChartInteraction.zoomedRange(timeRange,
                                                     by: ChartInteraction.timeZoomFactor(dy: dy),
                                                     minView: minView,
                                                     maxView: maxView)
        }
        // 平移 / 缩小时间窗都可能把左缘推到已加载边界之前 → 按需补载更早历史。
        maybeLoadOlderHistory()
    }

    /// 时间右缘：上限不越过当前时间 + 12s 采样余量。
    ///
    /// 下限：**已回溯到文件头**时停在最早样本 + 20s；尚未到达文件头时允许再把
    /// 视窗左缘往更早推最多一个窗口，用于触发更早历史的按需补载 ——
    /// 否则拖动到已加载边界就停住，无法继续回看。
    private func clampEnd(_ d: Date) -> Date {
        let now = Date()
        guard !logger.reachedHistoryStart, let earliest = logger.samples.first?.t else {
            return ChartInteraction.clampedEnd(d, now: now, earliest: logger.samples.first?.t)
        }
        let capped = ChartInteraction.clampedEnd(d, now: now, earliest: nil)
        return max(capped, earliest.addingTimeInterval(-timeRange))
    }

    /// 视窗左缘越过内存里的最早样本时，请求补载一页更早历史。
    private func maybeLoadOlderHistory() {
        guard !logger.reachedHistoryStart,
              let earliest = logger.samples.first?.t,
              endTime.addingTimeInterval(-timeRange) < earliest else {
            awaitingOlderHistory = false
            return
        }
        awaitingOlderHistory = true
        logger.loadOlderHistory()
    }

    private func fitToAll() {
        guard let t0 = logger.samples.first?.t,
              let t1 = logger.samples.last?.t else {
            endTime = Date(); timeRange = 6 * 3600
            return
        }
        let span = t1.timeIntervalSince1970 - t0.timeIntervalSince1970
        timeRange = min(maxView, max(minView, span))
        endTime = Date()
        followLive = true
        awaitingOlderHistory = false
    }
}

// MARK: - 配色

/// 本面板独有的系列配色。温度 / 容量 / 剩余时间与历史图表的系列色刻意错开，
/// 避免用户把两套曲线的颜色含义混在一起。
private enum AnalysisPalette {
    static let temperature = Color(red: 0.96, green: 0.52, blue: 0.18)
    static let capacity = Color(red: 0.16, green: 0.80, blue: 0.62)
    static let remaining = Color(red: 0.30, green: 0.62, blue: 0.95)
    static let health = Color(red: 0.96, green: 0.75, blue: 0.20)
    static let cycles = Color(red: 0.95, green: 0.45, blue: 0.42)
    static let voltage = Color(red: 0.66, green: 0.48, blue: 0.95)
    static let current = Color(red: 0.10, green: 0.72, blue: 0.78)
    static let state = Color(red: 0.55, green: 0.57, blue: 0.60)
}

// MARK: - 实际绘图对象

/// 上图（温度左轴 + 当前容量右轴）与下图（剩余时间）共用时间轴。
private struct AnalysisDraw {
    let visibleSamples: [PowerSample]
    let startE: Double
    let endE: Double
    let plot: ChartPlot
    let tempRange: ClosedRange<Double>
    let capRange: ClosedRange<Double>
    let remainRange: ClosedRange<Double>

    private var span: Double { max(1e-9, endE - startE) }

    func render(context: GraphicsContext, hover: ChartHoverInfo?) {
        var clip = Path()
        clip.addRect(CGRect(x: plot.minX, y: plot.top, width: plot.plotW, height: plot.plotH))
        context.drawLayer { layer in
            layer.clip(to: clip)

            // 上图：温度（左轴）+ 当前容量（右轴）。
            grid([0.0, 0.5, 1.0], yTop: plot.topY, height: plot.topH, in: layer)
            stroke(points({ $0.temperatureCelsius }, range: tempRange,
                          yTop: plot.topY, yBot: plot.topBottom),
                   color: AnalysisPalette.temperature, in: layer)
            stroke(points({ sample in sample.currentCapacity.map { Double($0) } },
                          range: capRange,
                          yTop: plot.topY, yBot: plot.topBottom),
                   color: AnalysisPalette.capacity, in: layer)

            // 下图：剩余时间（分钟，仅取有效值；-1 / -2 哨兵不画）。
            grid([0.0, 0.5, 1.0], yTop: plot.bottomY, height: plot.bottomH, in: layer)
            stroke(points({ sample -> Double? in
                guard let m = sample.remainingMinutes, m >= 0 else { return nil }
                return Double(m)
            }, range: remainRange, yTop: plot.bottomY, yBot: plot.bottomBottom),
                   color: AnalysisPalette.remaining, in: layer)

            // 共享时间网格（纵向）。
            for tick in timeTicks() {
                let xx = timeX(tick)
                if xx < plot.minX || xx > plot.maxX { continue }
                var p = Path()
                p.move(to: CGPoint(x: xx, y: plot.top))
                p.addLine(to: CGPoint(x: xx, y: plot.top + plot.plotH))
                layer.stroke(p, with: .color(.gray.opacity(0.12)), lineWidth: 1)
            }
        }

        // 上图左轴：温度（℃）。
        drawAxisTicks(range: tempRange, x: plot.minX, align: .trailing,
                      yTop: plot.topY, height: plot.topH, in: context) {
            LocalizedFormat.number($0, decimals: 1)
        }
        // 上图右轴：当前容量（mAh）。
        drawAxisTicks(range: capRange, x: plot.maxX, align: .leading,
                      yTop: plot.topY, height: plot.topH, in: context) {
            LocalizedFormat.number($0, decimals: 0)
        }
        // 下图左轴：剩余时间（分钟）。
        drawAxisTicks(range: remainRange, x: plot.minX, align: .trailing,
                      yTop: plot.bottomY, height: plot.bottomH, in: context) {
            LocalizedFormat.number($0, decimals: 0)
        }

        // 轴单位标签。
        let celsius = Text(L("analysis.unit.celsius"))
            .font(.system(size: 9)).foregroundColor(.gray)
        context.draw(celsius, at: CGPoint(x: plot.minX - 4, y: plot.top - 1), anchor: .bottomTrailing)
        let mAh = Text(L("health.unit.mah.short"))
            .font(.system(size: 9)).foregroundColor(.gray)
        context.draw(mAh, at: CGPoint(x: plot.maxX + 4, y: plot.top - 1), anchor: .bottomLeading)
        let minutes = Text(L("analysis.unit.minutes"))
            .font(.system(size: 9)).foregroundColor(.gray)
        context.draw(minutes, at: CGPoint(x: plot.minX - 4, y: plot.bottomY - 1), anchor: .bottomTrailing)

        // 底部共享时间轴。
        let template = Self.xTemplate(for: span)
        for tick in timeTicks() {
            let xx = timeX(tick)
            if xx < plot.minX || xx > plot.maxX { continue }
            let date = Date(timeIntervalSince1970: tick)
            let text = Text(LocalizedFormat.date(date, template: template))
                .font(.system(size: 9)).foregroundColor(.gray)
            context.draw(text, at: CGPoint(x: xx, y: plot.top + plot.plotH + 12), anchor: .top)
        }

        // 无数据占位。
        if visibleSamples.isEmpty {
            let text = Text(L("analysis.empty_placeholder"))
                .font(.system(size: 10)).foregroundColor(.gray)
            context.draw(text, at: CGPoint(x: plot.minX + plot.plotW / 2,
                                           y: plot.top + plot.plotH / 2))
        }

        if let hover {
            ChartHover.draw(hover, in: context, plot: plot,
                            yTop: plot.topY, yBottom: plot.bottomBottom,
                            span: span, lineOpacity: 0.5)
        }
    }

    private func grid(_ fractions: [Double], yTop: Double, height: Double, in layer: GraphicsContext) {
        for f in fractions {
            let yy = yTop + height - f * height
            var p = Path()
            p.move(to: CGPoint(x: plot.minX, y: yy))
            p.addLine(to: CGPoint(x: plot.maxX, y: yy))
            layer.stroke(p, with: .color(.gray.opacity(f == 0.5 ? 0.10 : 0.06)), lineWidth: 1)
        }
    }

    private func drawAxisTicks(range: ClosedRange<Double>, x: Double, align: UnitPoint,
                               yTop: Double, height: Double, in ctx: GraphicsContext,
                               format: (Double) -> String) {
        let lo = range.lowerBound, hi = range.upperBound
        let s = max(1e-9, hi - lo)
        let inward: CGFloat = align == .leading ? 4 : -4
        for f in [0.0, 0.5, 1.0] {
            let v = lo + f * s
            let yy = yTop + height - f * height
            var p = Path()
            p.move(to: CGPoint(x: x, y: yy))
            p.addLine(to: CGPoint(x: x + inward, y: yy))
            ctx.stroke(p, with: .color(.gray.opacity(0.5)), lineWidth: 1)
            let t = Text(format(v)).font(.system(size: 8)).foregroundColor(.gray)
            ctx.draw(t, at: CGPoint(x: x - inward * 1.5, y: yy), anchor: align)
        }
    }

    /// 逐点采样：`nil`（未知）直接跳过，不伪造 0。
    private func points(_ v: (PowerSample) -> Double?, range: ClosedRange<Double>,
                        yTop: Double, yBot: Double) -> [CGPoint] {
        let lo = range.lowerBound, hi = range.upperBound
        let s = max(1e-9, hi - lo)
        var pts: [CGPoint] = []
        pts.reserveCapacity(visibleSamples.count + 2)
        for sample in visibleSamples {
            guard let val = v(sample) else { continue }
            let x = timeX(sample.t.timeIntervalSince1970)
            let norm = (val - lo) / s
            let y = yBot - norm * (yBot - yTop)
            pts.append(CGPoint(x: x, y: max(yTop, min(yBot, y))))
        }
        if let first = pts.first { pts.insert(CGPoint(x: plot.minX, y: first.y), at: 0) }
        if let last = pts.last { pts.append(CGPoint(x: plot.maxX, y: last.y)) }
        return pts
    }

    private func stroke(_ pts: [CGPoint], color: Color, in layer: GraphicsContext) {
        ChartDrawing.strokePoints(pts, color: color, in: layer)
    }

    private func timeX(_ epoch: Double) -> Double {
        plot.minX + (epoch - startE) / span * plot.plotW
    }

    private func timeTicks() -> [Double] {
        let step = ChartAxes.niceTimeStep(span, minimumStep: 60)
        var out: [Double] = []
        var v = ceil(startE / step) * step
        while v <= endE + step {
            out.append(v)
            v += step
        }
        return out
    }

    private static func xTemplate(for span: Double) -> String {
        if span <= 3600 { return "jm" }
        if span <= 86400 { return "MMdj" }
        return "Md"
    }
}
