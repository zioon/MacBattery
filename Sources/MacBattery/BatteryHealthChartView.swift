import SwiftUI
import AppKit
import MacBatteryCore

/// 电池健康信息图表：上图将「设计容量 + 当前最大容量」（左轴，mAh）与「电池健康度」
/// （右轴副坐标，%）合成一张图，三条折线共共享时间轴；下图单独展示循环次数。
/// 默认时间跨度 1 个月（30 天）。
///
/// 交互（参照主图 PowerChartView）：
/// - 拖拽 / 横向滚动：左右平移时间；Option + 纵向滚动：缩放各行 y 轴范围。
/// - 纵向滚动：缩放时间窗；
/// - 「适合窗口」：回到全部数据并复位 y 轴自适应，恢复实时跟随。
struct BatteryHealthChartView: View {

    @ObservedObject var healthLogger: BatteryHealthLogger
    /// 语言变化时驱动本视图重绘（不必额外注入参数，直接观察共享实例）。
    @ObservedObject private var localization: LocalizationManager

    // MARK: 可见范围与缩放状态

    @State private var timeRange: TimeInterval = 30 * 86400
    @State private var endTime: Date = Date()
    @State private var followLive = true
    @State private var autoY = true
    /// 各绘图轴的范围：0=容量轴（上图左，mAh）1=健康度轴（上图右副坐标，%）2=循环次数轴（下图）。
    @State private var yMin: [Double] = [0, 50, 0]
    @State private var yMax: [Double] = [10_000, 100, 500]

    /// 鼠标在图表内的悬停位置（相对画布全尺寸，y 向下，nil 表示已离开）。
    @State private var hoverPoint: CGPoint?

    @GestureState private var dragBase: DragBase?
    private struct DragBase { let endTime: Date }

    private var minView: TimeInterval { 10 * 60 }
    private var maxView: TimeInterval { 365 * 86400 }

    /// 快捷时间范围预设（秒）：1 天 / 1 周 / 1 月 / 1 季 / 1 年。
    static let windowPresets: [TimeInterval] = [86400, 7 * 86400, 30 * 86400, 90 * 86400, 365 * 86400]

    // MARK: 指标定义

    /// 一个健康指标：标题 / 颜色 / 取值函数 / 格式化函数。
    struct HealthMetric {
        let title: String
        let color: Color
        let value: (BatteryHealthSample) -> Double
        let format: (Double) -> String
    }

    /// 上图左轴（容量，mAh）：设计容量 + 当前最大容量，共轴。
    ///
    /// ⚠️ 必须是计算属性（`static var`）而非 `static let`：标题与数值格式都随语言变化，
    /// 用 `static let` 缓存住会导致**切换语言后图例永远停在旧语言**。
    private static var capacityMetrics: [HealthMetric] {
        [
            HealthMetric(title: L("health.metric.max_capacity"),
                         color: Color(red: 0.16, green: 0.85, blue: 0.62),
                         value: { Double($0.maxCapacity) },
                         format: { L("health.unit.mah", Int($0)) }),
            HealthMetric(title: L("health.metric.design_capacity"),
                         color: Color(red: 0.30, green: 0.62, blue: 0.95),
                         value: { Double($0.designCapacity) },
                         format: { L("health.unit.mah", Int($0)) })
        ]
    }

    /// 上图右轴（副坐标，%）：电池健康度。
    private static var healthMetric: HealthMetric {
        HealthMetric(title: L("health.metric.health_pct"),
                     color: Color(red: 0.96, green: 0.75, blue: 0.20),
                     value: { $0.healthPercent },
                     format: { L("health.unit.pct", LocalizedFormat.number($0, decimals: 1)) })
    }

    /// 下图（循环次数）。
    private static var cycleMetric: HealthMetric {
        HealthMetric(title: L("health.metric.cycles"),
                     color: Color(red: 0.95, green: 0.45, blue: 0.42),
                     value: { Double($0.cycleCount) },
                     format: { LP("health.unit.cycles", count: Int($0)) })
    }

    /// 顶部指标条展示的全部指标（容量 2 项 + 健康度 + 循环次数）。
    private static var allMetrics: [HealthMetric] { capacityMetrics + [healthMetric, cycleMetric] }

    init(healthLogger: BatteryHealthLogger) {
        self.healthLogger = healthLogger
        self.localization = LocalizationManager.shared
        _endTime = State(initialValue: Date())
    }

    var body: some View {
        // 布局与历史窗口一致：顶部图例 → 中间图表 → 底部时间窗工具条。
        VStack(spacing: 8) {
            header
            chartArea
            presetBar
        }
        .padding(12)
        .frame(minWidth: 640, minHeight: 340)

        // 实时跟随：来一条新样本就前推右缘。
        .onChange(of: healthLogger.samples.last?.t) { t in
            if followLive, let t = t {
                endTime = t
            }
        }
    }

    // MARK: - 头部（图例 + 各指标当前值，样式与历史图表一致）

    private var header: some View {
        HStack(spacing: 12) {
            ForEach(Array(Self.allMetrics.enumerated()), id: \.offset) { _, m in
                legendChip(m)
            }
            Spacer()
        }
        .font(.caption)
    }

    // MARK: - 底部时间窗工具条（位置与历史图表一致，在图表下方）

    private var presetBar: some View {
        HStack(spacing: 10) {
            Text(summaryText)
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            // 轴说明，与历史图表的「左轴：% · 右轴：W / V / A」对应。
            Text(L("health.axis_hint"))
                .font(.caption2)
                .foregroundColor(.secondary)
            // 参数是文案键名，由 windowPresetButton 内部经 L() 取。
            windowPresetButton("health.window.1d", Self.windowPresets[0])
            windowPresetButton("health.window.1w", Self.windowPresets[1])
            windowPresetButton("health.window.1m", Self.windowPresets[2])
            windowPresetButton("health.window.1q", Self.windowPresets[3])
            windowPresetButton("health.window.1y", Self.windowPresets[4])
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

    /// 底部信息：样本条数 + 当前查看的时间窗（与历史图表一致）。
    private var summaryText: String {
        LP("chart.summary.samples", count: healthLogger.samples.count, timeText(timeRange))
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        ChartAxes.timeText(seconds)
    }

    /// 当前命中的时间范围预设（未命中则返回 nil，视为「全部」选中）。
    private var activeWindowPreset: TimeInterval? {
        Self.windowPresets.first { $0 == timeRange }
    }

    /// 时间范围按钮。参数是**文案键名**（不是最终文案），由 L() 取。
    private func windowPresetButton(_ key: String, _ seconds: TimeInterval) -> some View {
        let active = activeWindowPreset == seconds
        return Button(L(key)) { setWindow(seconds) }
            .buttonStyle(.plain)
            .font(.caption.weight(active ? .semibold : .regular))
            .foregroundColor(active ? Color.accentColor : .primary)
    }

    /// 切换到指定时间范围：回到实时跟随、右缘贴住最新样本并复位 y 轴自适应。
    private func setWindow(_ seconds: TimeInterval) {
        timeRange = min(max(seconds, minView), maxView)
        followLive = true
        if let t = healthLogger.samples.last?.t { endTime = t }
        autoY = true
    }

    private func legendChip(_ m: HealthMetric) -> some View {
        HStack(spacing: 4) {
            Circle().fill(m.color).frame(width: 8, height: 8)
            Text(m.title)
                .foregroundColor(.secondary)
            Text(currentValueText(m))
                .foregroundColor(.primary)
                .fontWeight(.semibold)
        }
    }

    private func currentValueText(_ m: HealthMetric) -> String {
        guard let last = healthLogger.samples.last else { return L("common.placeholder") }
        let v = m.value(last)
        return m.format(v)
    }

    // MARK: - 图表区域

    private var chartArea: some View {
        GeometryReader { geo in
            let plot = ChartPlot(outer: geo.size, left: 46, right: 44, top: 8, bottom: 26)
            let draw = buildDraw(plot)
            let hover = healthHoverInfo(hoverX: hoverPoint?.x, plot: plot)

            ZStack {
                Canvas { ctx, _ in draw.render(context: ctx, hover: hover) }
                    .background(Color.black.opacity(0.03))

                // 滚轮：横向平移 / 纵向缩放时间窗 / Option 缩放 y 轴；悬停定位。
                ScrollWheelCatcher { dx, dy, option in
                    handleScroll(dx: dx, dy: dy, option: option, plot: plot)
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

    private func buildDraw(_ plot: ChartPlot) -> HealthDraw {
        let startE = endTime.timeIntervalSince1970 - timeRange
        let endE = endTime.timeIntervalSince1970
        let samples = healthLogger.samples

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

        func rangeFor(_ i: Int, _ auto: () -> ClosedRange<Double>) -> ClosedRange<Double> {
            if autoY {
                return auto()
            } else {
                let lo = yMin[i], hi = max(yMin[i] + 1e-9, yMax[i])
                return lo...hi
            }
        }
        let capRange = rangeFor(0) { autoRange(visible, metrics: Self.capacityMetrics) }
        let healthRange = rangeFor(1) { autoRange(visible, metric: Self.healthMetric) }
        let cycleRange = rangeFor(2) { autoRange(visible, metric: Self.cycleMetric) }

        return HealthDraw(
            visibleSamples: visible,
            startE: startE, endE: endE,
            plot: plot,
            capacityMetrics: Self.capacityMetrics,
            healthMetric: Self.healthMetric,
            cycleMetric: Self.cycleMetric,
            capRange: capRange,
            healthRange: healthRange,
            cycleRange: cycleRange
        )
    }

    /// 按可见样本为该指标自适应 y 范围，带 10% 内边距，最小跨度 1。
    private func autoRange(_ visible: [BatteryHealthSample], metric: HealthMetric) -> ClosedRange<Double> {
        autoRange(visible, metrics: [metric])
    }

    /// 按可见样本为该组指标自适应 y 范围（取组内全部指标值的 min/max），带 10% 内边距，最小跨度 1。
    private func autoRange(_ visible: [BatteryHealthSample], metrics: [HealthMetric]) -> ClosedRange<Double> {
        guard !visible.isEmpty else { return 0...100 }
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for s in visible {
            for m in metrics {
                let v = m.value(s)
                lo = min(lo, v); hi = max(hi, v)
            }
        }
        guard lo.isFinite, hi.isFinite else { return 0...100 }
        if hi - lo < 1 { let m = (lo + hi) / 2; lo = m - 1; hi = m + 1 }
        let pad = (hi - lo) * 0.10
        var a = lo - pad, b = hi + pad
        if b - a < 2 { let m = (a + b) / 2; a = m - 1; b = m + 1 }
        return max(0, a)...b
    }

    // MARK: - 悬停

    /// 由鼠标 x 坐标定位最近的健康样本，生成跨两个绘图区域的数值浮层所需数据。
    private func healthHoverInfo(hoverX: CGFloat?, plot: ChartPlot) -> ChartHoverInfo? {
        guard let hx = hoverX, hx >= plot.minX, hx <= plot.maxX else { return nil }
        let startE = endTime.timeIntervalSince1970 - timeRange
        let targetE = startE + Double(hx - plot.minX) / plot.plotW * timeRange
        guard let s = ChartInteraction.nearestSample(upTo: targetE, in: healthLogger.samples, timestamp: { $0.t }) else { return nil }
        let x = plot.minX + (s.t.timeIntervalSince1970 - startE) / timeRange * plot.plotW
        let rows = Self.allMetrics.map { m in
            ChartHoverInfo.Row(color: m.color, title: m.title, value: m.format(m.value(s)))
        }
        return ChartHoverInfo(x: x, date: s.t, rows: rows)
    }

    /// 最近样本定位已抽到 Charting/ChartInteraction（历史图共用）。

    // MARK: - 交互

    private func dragTranslation(_ tr: CGSize, plot: ChartPlot) {
        guard let base = dragBase else { return }
        followLive = false
        if let delta = ChartInteraction.panSeconds(dx: tr.width, plotWidth: plot.plotW, timeRange: timeRange) {
            endTime = clampEnd(base.endTime - delta)
        }
    }

    private func handleScroll(dx: Double, dy: Double, option: Bool, plot: ChartPlot) {
        if option {
            // Option + 纵向滚动 → 缩放各 y 轴。
            if dy != 0 {
                zoomY(by: ChartInteraction.axesZoomFactor(dy: dy))
                autoY = false
            }
            return
        }
        if abs(dx) > 0 {
            followLive = false
            if let delta = ChartInteraction.panSeconds(dx: dx, plotWidth: plot.plotW, timeRange: timeRange) {
                endTime = clampEnd(endTime - delta)
            }
        }
        if dy != 0 {
            zoomTime(by: ChartInteraction.timeZoomFactor(dy: dy))
        }
    }

    private func zoomTime(by factor: Double) {
        timeRange = ChartInteraction.zoomedRange(timeRange, by: factor, minView: minView, maxView: maxView)
    }

    /// 以一个统一比例缩放所有行 y 轴（围绕各自中心）。
    private func zoomY(by factor: Double) {
        for i in yMin.indices {
            let a = yMin[i], b = yMax[i]
            let center = (a + b) / 2
            let span = max(0.1, (b - a) / factor)
            yMin[i] = center - span / 2
            yMax[i] = center + span / 2
        }
    }

    private func clampEnd(_ d: Date) -> Date {
        ChartInteraction.clampedEnd(d, now: Date(), earliest: healthLogger.samples.first?.t)
    }

    private func fitToAll() {
        guard let t0 = healthLogger.samples.first?.t,
              let t1 = healthLogger.samples.last?.t else {
            endTime = Date(); timeRange = 30 * 86400
            return
        }
        let span = t1.timeIntervalSince1970 - t0.timeIntervalSince1970
        var range = max(15, span)
        if range > maxView { range = maxView }
        timeRange = range
        endTime = Date()
        autoY = true
        followLive = true
    }

    /// 确认后清空电池健康日志（内存 + 磁盘 CSV），历史不可恢复。
    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = L("alert.reset_health.title")
        alert.informativeText = L("alert.reset_health.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("common.reset"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        healthLogger.reset()
        // 复位视图状态，回到空数据的默认视图。
        endTime = Date()
        timeRange = 30 * 86400
        autoY = true
        followLive = true
    }
}

// MARK: - 实际绘图对象

private struct HealthDraw {
    let visibleSamples: [BatteryHealthSample]
    let startE: Double
    let endE: Double
    let plot: ChartPlot
    let capacityMetrics: [BatteryHealthChartView.HealthMetric]
    let healthMetric: BatteryHealthChartView.HealthMetric
    let cycleMetric: BatteryHealthChartView.HealthMetric
    let capRange: ClosedRange<Double>
    let healthRange: ClosedRange<Double>
    let cycleRange: ClosedRange<Double>

    private var span: Double { max(1e-9, endE - startE) }

    func render(context: GraphicsContext, hover: ChartHoverInfo?) {
        var clip = Path()
        clip.addRect(CGRect(x: plot.minX, y: plot.top, width: plot.plotW, height: plot.plotH))
        context.drawLayer { layer in
            layer.clip(to: clip)
            // 上图：容量轴横向网格（下 / 中 / 上）
            grid(f: [0.0, 0.5, 1.0], yTop: plot.topY, height: plot.topH, in: layer)
            // 上图：容量折线 × 2（设计容量 + 当前最大容量，共左轴）
            for m in capacityMetrics {
                stroke(points(v: { m.value($0) }, range: capRange,
                             yTop: plot.topY, yBot: plot.topBottom),
                       color: m.color, in: layer)
            }
            // 上图：健康度折线（右轴副坐标）
            stroke(points(v: { healthMetric.value($0) }, range: healthRange,
                          yTop: plot.topY, yBot: plot.topBottom),
                   color: healthMetric.color, in: layer)
            // 下图：循环次数网格 + 折线
            grid(f: [0.0, 0.5, 1.0], yTop: plot.bottomY, height: plot.bottomH, in: layer)
            stroke(points(v: { cycleMetric.value($0) }, range: cycleRange,
                          yTop: plot.bottomY, yBot: plot.bottomBottom),
                   color: cycleMetric.color, in: layer)
            // 共享时间网格（纵向）
            for tick in timeTicks() {
                let xx = timeX(tick)
                if xx < plot.minX || xx > plot.maxX { continue }
                var p = Path()
                p.move(to: CGPoint(x: xx, y: plot.top))
                p.addLine(to: CGPoint(x: xx, y: plot.top + plot.plotH))
                layer.stroke(p, with: .color(.gray.opacity(0.12)), lineWidth: 1)
            }
        }

        // 上图左轴刻度（容量 mAh）
        drawAxisTicks(range: capRange, x: plot.minX, align: .trailing,
                      yTop: plot.topY, height: plot.topH, in: context) {
            LocalizedFormat.number($0, decimals: 0)
        }
        // 上图右轴刻度（健康度 %，副坐标）
        drawAxisTicks(range: healthRange, x: plot.maxX, align: .leading,
                      yTop: plot.topY, height: plot.topH, in: context) {
            L("health.unit.pct", LocalizedFormat.number($0, decimals: 0))
        }
        // 左右轴单位标签（顶部分别标注 mAh / %）
        let mAh = Text(L("health.unit.mah.short")).font(.system(size: 9)).foregroundColor(.gray)
        context.draw(mAh, at: CGPoint(x: plot.minX - 4, y: plot.top - 1), anchor: .bottomTrailing)
        let pct = Text(L("health.unit.pct.sign")).font(.system(size: 9)).foregroundColor(.gray)
        context.draw(pct, at: CGPoint(x: plot.maxX + 4, y: plot.top - 1), anchor: .bottomLeading)

        // 下图行标题（左边缘，靠上）
        let cTitle = Text(cycleMetric.title).font(.system(size: 9, weight: .semibold))
            .foregroundColor(cycleMetric.color)
        context.draw(cTitle, at: CGPoint(x: plot.minX - 6, y: plot.bottomY + 1), anchor: .topTrailing)

        // 底部共享时间轴
        let template = Self.xTemplate(for: span)
        for tick in timeTicks() {
            let xx = timeX(tick)
            if xx < plot.minX || xx > plot.maxX { continue }
            let date = Date(timeIntervalSince1970: tick)
            let text = Text(LocalizedFormat.date(date, template: template))
                .font(.system(size: 9)).foregroundColor(.gray)
            context.draw(text, at: CGPoint(x: xx, y: plot.top + plot.plotH + 12), anchor: .top)
        }

        // 无数据占位
        if visibleSamples.isEmpty {
            let text = Text(L("health.empty_placeholder"))
                .font(.system(size: 10)).foregroundColor(.gray)
            context.draw(text, at: CGPoint(x: plot.minX + plot.plotW / 2, y: plot.top + plot.plotH / 2))
        }

        // 悬停：跨两个区域的竖线 + 该时刻数值浮层。
        if let hover {
            drawHover(hover, in: context)
        }
    }

    /// 绘制水平网格线（下 / 中 / 上 三等分位置）。
    private func grid(f fractions: [Double], yTop: Double, height: Double, in layer: GraphicsContext) {
        for f in fractions {
            let yy = yTop + height - f * height
            var p = Path()
            p.move(to: CGPoint(x: plot.minX, y: yy))
            p.addLine(to: CGPoint(x: plot.maxX, y: yy))
            layer.stroke(p, with: .color(.gray.opacity(f == 0.5 ? 0.10 : 0.06)), lineWidth: 1)
        }
    }

    /// 沿纵轴绘制下 / 中 / 上三个刻度与数值标签（用于左 / 右轴）。
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

    /// 绘制悬停竖线（跨整个图表区）+ 时间与 4 项指标数值浮层。
    private func drawHover(_ hover: ChartHoverInfo, in ctx: GraphicsContext) {
        // 竖线贯穿上 / 下两个分区；线宽与透明度保留健康图原有观感。
        ChartHover.draw(hover, in: ctx, plot: plot,
                        yTop: plot.topY, yBottom: plot.bottomBottom,
                        span: span, lineOpacity: 0.5)
    }

    private func points(v: (BatteryHealthSample) -> Double, range: ClosedRange<Double>,
                        yTop: Double, yBot: Double) -> [CGPoint] {
        let lo = range.lowerBound, hi = range.upperBound
        let s = max(1e-9, hi - lo)
        var pts: [CGPoint] = []
        pts.reserveCapacity(visibleSamples.count + 2)
        for sp in visibleSamples {
            let x = timeX(sp.t.timeIntervalSince1970)
            let val = v(sp)
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

    /// 时间轴刻度用的日期字段模板（由系统按区域解析，12/24 小时制与日期顺序自动适配）。
    /// 原先写死 `dateFormat`，在 12 小时制区域会显示成 24 小时制文本。
    private static func xTemplate(for span: Double) -> String {
        if span <= 3600 { return "jm" }
        if span <= 86400 { return "MMdj" }
        return "Md"
    }
}