import SwiftUI
import AppKit

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

    /// 实时容量（当前最大容量 × 当前电量百分比）。电量实时变化，定时刷新跟随。
    @State private var liveCapacityText: String = "--"
    /// 实时容量刷新定时器（跟随电量变化，健康历史仍按低频采样）。
    private let liveTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    /// 实时容量标识色（与「当前最大容量」同色系）。
    private static let liveCapacityColor = Color(red: 0.22, green: 0.80, blue: 0.45)

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

    /// 上图左轴（容量，mAh）：设计容量 + 当前最大容量 + 实时容量，共轴。
    private static let capacityMetrics: [HealthMetric] = [
        HealthMetric(title: "当前最大容量",
                     color: Color(red: 0.16, green: 0.85, blue: 0.62),
                     value: { Double($0.maxCapacity) },
                     format: { "\(Int($0)) mAh" }),
        HealthMetric(title: "设计容量",
                     color: Color(red: 0.30, green: 0.62, blue: 0.95),
                     value: { Double($0.designCapacity) },
                     format: { "\(Int($0)) mAh" }),
        HealthMetric(title: "实时容量",
                     color: Color(red: 0.22, green: 0.80, blue: 0.45),
                     // 电量未知（旧 5 列文件回填为 -1）时按 0 处理，避免负值破坏轴范围。
                     value: { Double($0.maxCapacity) * Double(max(0, $0.levelPercent)) / 100.0 },
                     format: { "\(Int($0)) mAh" })
    ]

    /// 上图右轴（副坐标，%）：电池健康度。
    private static let healthMetric = HealthMetric(title: "电池健康度",
                     color: Color(red: 0.96, green: 0.75, blue: 0.20),
                     value: { $0.healthPercent },
                     format: { String(format: "%.1f%%", $0) })

    /// 下图（循环次数）。
    private static let cycleMetric = HealthMetric(title: "循环次数",
                     color: Color(red: 0.95, green: 0.45, blue: 0.42),
                     value: { Double($0.cycleCount) },
                     format: { "\(Int($0)) 次" })

    /// 顶部指标条展示的全部指标（容量 2 项 + 健康度 + 循环次数）。
    private static var allMetrics: [HealthMetric] { capacityMetrics + [healthMetric, cycleMetric] }

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
            // 顶部指标条：除「实时容量」外（由下方 liveCapacityChip 实时展示）。
            ForEach(Array(Self.allMetrics.enumerated())
                .filter { $0.element.title != "实时容量" }, id: \.offset) { _, m in
                    legendChip(m)
            }
            liveCapacityChip
            Spacer()
        }
        .font(.caption)
        .onReceive(liveTimer) { _ in refreshLiveCapacity() }
    }

    /// 实时容量芯片：当前最大容量 × 当前电量百分比。
    private var liveCapacityChip: some View {
        HStack(spacing: 4) {
            Circle().fill(Self.liveCapacityColor).frame(width: 7, height: 7)
            Text("实时容量")
                .foregroundColor(.secondary)
            Text(liveCapacityText)
                .foregroundColor(.primary)
                .fontWeight(.semibold)
        }
    }

    /// 计算并刷新实时容量 = 当前最大容量 ×（电量百分比 / 100）。滚动时不会阻塞。
    private func refreshLiveCapacity() {
        guard let last = healthLogger.samples.last, last.maxCapacity > 0 else {
            liveCapacityText = "--"
            return
        }
        let level = BatteryReader.level()
        liveCapacityText = "\(Int(Double(last.maxCapacity) * Double(level) / 100.0)) mAh"
    }

    // MARK: - 底部时间窗工具条（位置与历史图表一致，在图表下方）

    private var presetBar: some View {
        HStack(spacing: 10) {
            Text(summaryText)
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
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
        }
    }

    /// 底部信息：样本条数 + 已记录持续时长（与历史图表样式一致）。
    private var summaryText: String {
        let duration: TimeInterval
        if let first = healthLogger.samples.first?.t,
           let last = healthLogger.samples.last?.t {
            duration = last.timeIntervalSince(first)
        } else {
            duration = 0
        }
        return "样本 \(healthLogger.samples.count) 个 · 已记录 " + timeText(duration)
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟" }
        if seconds < 86400 { return String(format: "%.1f 小时", seconds / 3600) }
        return String(format: "%.1f 天", seconds / 86400)
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
            let plot = HealthPlot(outer: geo.size, left: 46, right: 44, top: 8, bottom: 26)
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
    private func healthHoverInfo(hoverX: CGFloat?, plot: HealthPlot) -> HealthHoverInfo? {
        guard let hx = hoverX, hx >= plot.minX, hx <= plot.maxX else { return nil }
        let startE = endTime.timeIntervalSince1970 - timeRange
        let targetE = startE + Double(hx - plot.minX) / plot.plotW * timeRange
        guard let s = nearestSample(upTo: targetE, in: healthLogger.samples) else { return nil }
        let x = plot.minX + (s.t.timeIntervalSince1970 - startE) / timeRange * plot.plotW
        let rows = Self.allMetrics.map { m in
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

/// 绘图区域：上图（容量左轴 + 健康度右轴副坐标，占约 2/3 高度）+ 下图（循环次数，约 1/3）。
private struct HealthPlot {
    let outer: CGSize
    let left, right, top, bottom: Double
    var gap: Double { 8 }

    var plotW: Double { max(10, outer.width - left - right) }
    var plotH: Double { max(10, outer.height - top - bottom) }
    var topRatio: Double { 0.62 }
    var topH: Double { max(10, plotH * topRatio) }
    var bottomH: Double { max(10, plotH - topH - gap) }
    var minX: Double { left }
    var maxX: Double { left + plotW }
    /// 上图区域（容量 / 健康度）。
    var topY: Double { top }
    var topBottom: Double { top + topH }
    /// 下图区域（循环次数）。
    var bottomY: Double { top + topH + gap }
    var bottomBottom: Double { top + plotH }
}

// MARK: - 实际绘图对象

private struct HealthDraw {
    let visibleSamples: [BatteryHealthSample]
    let startE: Double
    let endE: Double
    let plot: HealthPlot
    let capacityMetrics: [BatteryHealthChartView.HealthMetric]
    let healthMetric: BatteryHealthChartView.HealthMetric
    let cycleMetric: BatteryHealthChartView.HealthMetric
    let capRange: ClosedRange<Double>
    let healthRange: ClosedRange<Double>
    let cycleRange: ClosedRange<Double>

    private var span: Double { max(1e-9, endE - startE) }

    func render(context: GraphicsContext, hover: HealthHoverInfo?) {
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
                      yTop: plot.topY, height: plot.topH, in: context) { "\(Int($0))" }
        // 上图右轴刻度（健康度 %，副坐标）
        drawAxisTicks(range: healthRange, x: plot.maxX, align: .leading,
                      yTop: plot.topY, height: plot.topH, in: context) { String(format: "%.0f%%", $0) }
        // 左右轴单位标签（顶部分别标注 mAh / %）
        let mAh = Text("mAh").font(.system(size: 9)).foregroundColor(.gray)
        context.draw(mAh, at: CGPoint(x: plot.minX - 4, y: plot.top - 1), anchor: .bottomTrailing)
        let pct = Text("%").font(.system(size: 9)).foregroundColor(.gray)
        context.draw(pct, at: CGPoint(x: plot.maxX + 4, y: plot.top - 1), anchor: .bottomLeading)

        // 下图行标题（左边缘，靠上）
        let cTitle = Text(cycleMetric.title).font(.system(size: 9, weight: .semibold))
            .foregroundColor(cycleMetric.color)
        context.draw(cTitle, at: CGPoint(x: plot.minX - 6, y: plot.bottomY + 1), anchor: .topTrailing)

        // 底部共享时间轴
        let formatter = Self.xFormatter(for: span)
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
    private func drawHover(_ hover: HealthHoverInfo, in ctx: GraphicsContext) {
        let x = CGFloat(hover.x)
        guard x >= plot.minX, x <= plot.maxX else { return }

        // 竖线跨全部两个区域。
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