import SwiftUI
import AppKit

/// 电池健康信息图表：位于主功率图表下方，4 项健康指标（当前最大容量 / 设计容量 / 电池健康度 / 循环次数）
/// 以「共享时间轴 + 每行独立自适应 y 轴」的 4 行子图展示。默认时间跨度 1 个月（30 天）。
///
/// 交互（参照主图 PowerChartView）：
/// - 拖拽 / 横向滚动：左右平移时间；Option + 纵向滚动：缩放各行 y 轴范围。
/// - 纵向滚动：缩放时间窗；
/// - 「适合窗口」：回到全部数据并复位 y 轴自适应，恢复实时跟随。
struct BatteryHealthChartView: View {

    @ObservedObject var healthLogger: BatteryHealthLogger

    // MARK: 可见范围与缩放状态

    @State private var timeRange: TimeInterval = 30 * 86400
    @State private var endTime: Date = Date()
    @State private var followLive = true
    @State private var autoY = true
    /// 每行的 y 轴范围（下标与 Self.metrics 一一对应）。
    @State private var yMin: [Double] = [0, 0, 50, 0]
    @State private var yMax: [Double] = [10_000, 10_000, 100, 500]

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

    private static let metrics: [HealthMetric] = [
        HealthMetric(title: "当前最大容量",
                     color: Color(red: 0.16, green: 0.85, blue: 0.62),
                     value: { Double($0.maxCapacity) },
                     format: { "\(Int($0)) mAh" }),
        HealthMetric(title: "设计容量",
                     color: Color(red: 0.30, green: 0.62, blue: 0.95),
                     value: { Double($0.designCapacity) },
                     format: { "\(Int($0)) mAh" }),
        HealthMetric(title: "电池健康度",
                     color: Color(red: 0.96, green: 0.75, blue: 0.20),
                     value: { $0.healthPercent },
                     format: { String(format: "%.1f%%", $0) }),
        HealthMetric(title: "循环次数",
                     color: Color(red: 0.95, green: 0.45, blue: 0.42),
                     value: { Double($0.cycleCount) },
                     format: { "\(Int($0)) 次" })
    ]

    init(healthLogger: BatteryHealthLogger) {
        self.healthLogger = healthLogger
        _endTime = State(initialValue: Date())
    }

    var body: some View {
        // 布局与历史窗口一致：顶部指标条 → 中间图表 → 底部时间窗工具条。
        VStack(spacing: 6) {
            header
            chartArea
            presetBar
        }
        .padding(.top, 8)
        .frame(minHeight: 240)

        // 实时跟随：来一条新样本就前推右缘。
        .onChange(of: healthLogger.samples.last?.t) { t in
            if followLive, let t = t {
                endTime = t
            }
        }
    }

    // MARK: - 头部（指标当前值）

    private var header: some View {
        HStack(spacing: 10) {
            Text("电池健康")
                .font(.headline)
                .foregroundColor(.primary)
            ForEach(Array(Self.metrics.enumerated()), id: \.offset) { _, m in
                legendChip(m)
            }
            Spacer()
        }
        .font(.caption)
    }

    // MARK: - 底部时间窗工具条（位置与历史图表一致，在图表下方）

    private var presetBar: some View {
        HStack(spacing: 10) {
            windowPresetButton("1d", Self.windowPresets[0])
            windowPresetButton("1w", Self.windowPresets[1])
            windowPresetButton("1m", Self.windowPresets[2])
            windowPresetButton("1q", Self.windowPresets[3])
            windowPresetButton("1y", Self.windowPresets[4])
            Button("全部") { fitToAll() }
                .buttonStyle(.plain)
                .font(.caption)
            Button("重置数据") { confirmReset() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.red)
            Spacer(minLength: 0)
        }
    }

    /// 当前命中的时间范围预设（未命中则返回 nil，视为「全部」选中）。
    private var activeWindowPreset: TimeInterval? {
        Self.windowPresets.first { $0 == timeRange }
    }

    /// 时间范围按钮。
    private func windowPresetButton(_ title: String, _ seconds: TimeInterval) -> some View {
        let active = activeWindowPreset == seconds
        return Button(title) { setWindow(seconds) }
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
            Circle().fill(m.color).frame(width: 7, height: 7)
            Text("\(m.title) ")
                .foregroundColor(.secondary)
            Text(currentValueText(m))
                .foregroundColor(.primary)
                .fontWeight(.semibold)
        }
    }

    private func currentValueText(_ m: HealthMetric) -> String {
        guard let last = healthLogger.samples.last else { return "--" }
        let v = m.value(last)
        return m.format(v)
    }

    // MARK: - 图表区域

    private var chartArea: some View {
        GeometryReader { geo in
            let plot = HealthPlot(outer: geo.size, left: 80, right: 10, top: 8, bottom: 18, rows: Self.metrics.count)
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

    private func buildDraw(_ plot: HealthPlot) -> HealthDraw {
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

        var yRanges: [ClosedRange<Double>] = []
        for (i, m) in Self.metrics.enumerated() {
            let r: ClosedRange<Double>
            if autoY {
                r = autoRange(visible, metric: m)
            } else {
                // 手动缩放后保持原范围，仅确保非空。
                let lo = yMin[i], hi = max(yMin[i] + 1e-9, yMax[i])
                r = lo...hi
            }
            yRanges.append(r)
        }

        return HealthDraw(
            visibleSamples: visible,
            startE: startE, endE: endE,
            plot: plot,
            metrics: Self.metrics,
            yRanges: yRanges
        )
    }

    /// 按可见样本为该指标自适应 y 范围，带 10% 内边距，最小跨度 1。
    private func autoRange(_ visible: [BatteryHealthSample], metric: HealthMetric) -> ClosedRange<Double> {
        guard !visible.isEmpty else { return 0...100 }
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for s in visible {
            let v = metric.value(s)
            lo = min(lo, v); hi = max(hi, v)
        }
        guard lo.isFinite, hi.isFinite else { return 0...100 }
        if hi - lo < 1 { let m = (lo + hi) / 2; lo = m - 1; hi = m + 1 }
        let pad = (hi - lo) * 0.10
        var a = lo - pad, b = hi + pad
        if b - a < 2 { let m = (a + b) / 2; a = m - 1; b = m + 1 }
        return max(0, a)...b
    }

    // MARK: - 悬停

    /// 由鼠标 x 坐标定位最近的健康样本，生成跨 4 行数值浮层所需数据。
    private func healthHoverInfo(hoverX: CGFloat?, plot: HealthPlot) -> HealthHoverInfo? {
        guard let hx = hoverX, hx >= plot.minX, hx <= plot.maxX else { return nil }
        let startE = endTime.timeIntervalSince1970 - timeRange
        let targetE = startE + Double(hx - plot.minX) / plot.plotW * timeRange
        guard let s = nearestSample(upTo: targetE, in: healthLogger.samples) else { return nil }
        let x = plot.minX + (s.t.timeIntervalSince1970 - startE) / timeRange * plot.plotW
        let rows = Self.metrics.map { m in
            HealthHoverInfo.Row(color: m.color, title: m.title, value: m.format(m.value(s)))
        }
        return HealthHoverInfo(x: x, date: s.t, rows: rows)
    }

    /// 序列中时间不超过 target 的最近一条（健康样本按时间升序）。
    private func nearestSample(upTo target: Double, in arr: [BatteryHealthSample]) -> BatteryHealthSample? {
        guard !arr.isEmpty else { return nil }
        var lo = 0, hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid].t.timeIntervalSince1970 <= target { lo = mid + 1 } else { hi = mid }
        }
        let idx = lo - 1
        return idx >= 0 ? arr[idx] : nil
    }

    // MARK: - 交互

    private func dragTranslation(_ tr: CGSize, plot: HealthPlot) {
        guard let base = dragBase else { return }
        followLive = false
        let ptsPerSec = plot.plotW / timeRange
        if ptsPerSec > 0 {
            endTime = clampEnd(base.endTime - tr.width / ptsPerSec)
        }
    }

    private func handleScroll(dx: Double, dy: Double, option: Bool, plot: HealthPlot) {
        if option {
            // Option + 纵向滚动 → 缩放各 y 轴。
            if dy != 0 {
                zoomY(by: bounded(exp(Double(-dy) * 0.015), 0.86, 1.16))
                autoY = false
            }
            return
        }
        if abs(dx) > 0 {
            followLive = false
            let ptsPerSec = plot.plotW / timeRange
            if ptsPerSec > 0 {
                endTime = clampEnd(endTime - dx / ptsPerSec)
            }
        }
        if dy != 0 {
            zoomTime(by: bounded(exp(Double(-dy) * 0.02), 0.84, 1.19))
        }
    }

    private func zoomTime(by factor: Double) {
        var newRange = timeRange / factor
        if newRange > maxView { newRange = maxView }
        if newRange < minView { newRange = minView }
        timeRange = newRange
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

    private func bounded(_ f: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(f, lo), hi)
    }

    private func clampEnd(_ d: Date) -> Date {
        let now = Date().addingTimeInterval(12)
        let earliest = healthLogger.samples.first?.t
        if d > now { return now }
        if let e = earliest, d < e.addingTimeInterval(20) { return e.addingTimeInterval(20) }
        return d
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
        alert.messageText = "重置健康数据"
        alert.informativeText = "将清空电池健康日志的全部历史数据（含磁盘 CSV），且不可恢复。确定重置？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        healthLogger.reset()
        // 复位视图状态，回到空数据的默认视图。
        endTime = Date()
        timeRange = 30 * 86400
        autoY = true
        followLive = true
    }
}

// MARK: - 悬停浮层数据

private struct HealthHoverInfo {
    let x: Double
    let date: Date
    let rows: [Row]

    struct Row {
        let color: Color
        let title: String
        let value: String
    }
}

// MARK: - 绘图区域

private struct HealthPlot {
    let outer: CGSize
    let left, right, top, bottom: Double
    let rows: Int
    var rowGap: Double { 6 }

    var plotW: Double { max(10, outer.width - left - right) }
    var plotH: Double { max(10, outer.height - top - bottom) }
    var rowH: Double { (plotH - Double(rows - 1) * rowGap) / Double(rows) }
    var minX: Double { left }
    var maxX: Double { left + plotW }

    func rowY(_ i: Int) -> Double { top + Double(i) * (rowH + rowGap) }
    func rowBottom(_ i: Int) -> Double { rowY(i) + rowH }
}

// MARK: - 实际绘图对象

private struct HealthDraw {
    let visibleSamples: [BatteryHealthSample]
    let startE: Double
    let endE: Double
    let plot: HealthPlot
    let metrics: [BatteryHealthChartView.HealthMetric]
    let yRanges: [ClosedRange<Double>]

    private var span: Double { max(1e-9, endE - startE) }

    func render(context: GraphicsContext, hover: HealthHoverInfo?) {
        var clip = Path()
        clip.addRect(CGRect(x: plot.minX, y: plot.top, width: plot.plotW, height: plot.plotH))
        context.drawLayer { layer in
            layer.clip(to: clip)
            // 各行的横向网格 + 折线
            for i in metrics.indices {
                let color = metrics[i].color
                let range = yRanges[i]
                let yTop = plot.rowY(i)
                let yBot = plot.rowBottom(i)
                // 行内网格（下 / 中 / 上）
                for f in [0.0, 0.5, 1.0] {
                    let yy = yBot - f * plot.rowH
                    var p = Path()
                    p.move(to: CGPoint(x: plot.minX, y: yy))
                    p.addLine(to: CGPoint(x: plot.maxX, y: yy))
                    layer.stroke(p, with: .color(.gray.opacity(f == 0.5 ? 0.10 : 0.06)), lineWidth: 1)
                }
                // 折线
                let pts = points(i: i, range: range, yTop: yTop, yBot: yBot)
                stroke(pts, color: color, in: layer)
            }
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

        // 行标题（不裁剪，左边缘靠上；取消 y 轴上下数据标记）
        for i in metrics.indices {
            let yTop = plot.rowY(i)
            let m = metrics[i]
            // 行标题（左边缘，靠上）
            let title = Text(m.title).font(.system(size: 9, weight: .semibold))
                .foregroundColor(m.color)
            context.draw(title, at: CGPoint(x: plot.minX - 6, y: yTop + 1), anchor: .topTrailing)
        }
        // 底部共享时间轴
        let formatter = Self.xFormatter(for: metrics.count > 0 ? self.span : 30 * 86400)
        for tick in timeTicks() {
            let xx = timeX(tick)
            if xx < plot.minX || xx > plot.maxX { continue }
            let date = Date(timeIntervalSince1970: tick)
            let text = Text(formatter.string(from: date)).font(.system(size: 9)).foregroundColor(.gray)
            context.draw(text, at: CGPoint(x: xx, y: plot.top + plot.plotH + 12), anchor: .top)
        }

        // 无数据占位
        if visibleSamples.isEmpty {
            let text = Text("暂无健康数据（应用运行后会随采样累积）")
                .font(.system(size: 10)).foregroundColor(.gray)
            context.draw(text, at: CGPoint(x: plot.minX + plot.plotW / 2, y: plot.top + plot.plotH / 2))
        }

        // 悬停：跨 4 行的竖线 + 该时刻数值浮层。
        if let hover {
            drawHover(hover, in: context)
        }
    }

    /// 绘制悬停竖线（跨整个图表区）+ 时间与 4 项指标数值浮层。
    private func drawHover(_ hover: HealthHoverInfo, in ctx: GraphicsContext) {
        let x = CGFloat(hover.x)
        guard x >= plot.minX, x <= plot.maxX else { return }

        // 竖线跨全部 4 行。
        var vp = Path()
        vp.move(to: CGPoint(x: x, y: plot.top))
        vp.addLine(to: CGPoint(x: x, y: plot.top + plot.plotH))
        ctx.stroke(vp, with: .color(.white.opacity(0.5)), lineWidth: 1)

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
        ctx.draw(timeText, at: CGPoint(x: bx, y: plot.top + 8), anchor: anchor)

        var yy = plot.top + 26
        for row in hover.rows {
            let line = Text("\(row.title)  \(row.value)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(row.color)
            ctx.draw(line, at: CGPoint(x: bx, y: yy), anchor: anchor)
            yy += 15
        }
    }

    private func points(i: Int, range: ClosedRange<Double>, yTop: Double, yBot: Double) -> [CGPoint] {
        let lo = range.lowerBound, hi = range.upperBound
        let s = max(1e-9, hi - lo)
        var pts: [CGPoint] = []
        pts.reserveCapacity(visibleSamples.count + 2)
        for sp in visibleSamples {
            let x = timeX(sp.t.timeIntervalSince1970)
            let v = metrics[i].value(sp)
            let norm = (v - lo) / s
            let y = yBot - norm * plot.rowH
            pts.append(CGPoint(x: x, y: max(yTop, min(yBot, y))))
        }
        if let first = pts.first { pts.insert(CGPoint(x: plot.minX, y: first.y), at: 0) }
        if let last = pts.last { pts.append(CGPoint(x: plot.maxX, y: last.y)) }
        return pts
    }

    private func stroke(_ pts: [CGPoint], color: Color, in layer: GraphicsContext) {
        guard pts.count >= 2 else { return }
        var path = Path()
        path.move(to: pts[0])
        for pt in pts.dropFirst() { path.addLine(to: pt) }
        layer.stroke(path, with: .color(color.opacity(0.9)),
                     style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
    }

    private func timeX(_ epoch: Double) -> Double {
        plot.minX + (epoch - startE) / span * plot.plotW
    }

    private func timeTicks() -> [Double] {
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
        let candidates: [Double] = [60, 120, 300, 600, 900, 1800,
                                    3600, 7200, 14400, 21600, 36000, 43200, 86400]
        let target = span / 6
        for c in candidates where c >= target { return c }
        return candidates.last ?? 86400
    }

    private static func xFormatter(for span: Double) -> DateFormatter {
        let f = DateFormatter()
        if span <= 3600 { f.dateFormat = "HH:mm" }
        else if span <= 86400 { f.dateFormat = "MM-dd HH:mm" }
        else { f.dateFormat = "MM-dd" }
        return f
    }
}