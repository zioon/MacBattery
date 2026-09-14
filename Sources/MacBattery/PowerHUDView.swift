import SwiftUI

/// 置顶挂件 UI：外层矩形充电环（完整底环 + 电量进度）环绕中间两行功率；
/// 内层一个整体的内环承接 CPU / RAM，上半环为 CPU、下半环为 RAM，各按占用率填充；
/// 内环外壁与充电环内壁完全重合（几何上严丝合缝）。
/// 充电环随电量平滑变色；充电时沿环流动高光，且充电图标周期性发光（环本身不晃动）。
/// 整体尺寸随 `scale` 缩放（基础宽高会随 scale 变化）。
struct PowerHUDView: View {

    @ObservedObject var monitor: PowerMonitor
    /// 缩放系数（0.8 / 1.0 / 1.3…）
    var scale: CGFloat = 1.0

    /// 充电图标发光脉动相位（仅充电时往复动画）。
    @State private var breathing = false

    /// 可见底盘边长（scale=1 时为 58×58）。
    private var contentSize: CGFloat { 58 }
    /// 四周额外的透明余量：给充电时的外发光 / 模糊留出空间，避免被窗口边界裁切。
    private var glowMargin: CGFloat { 6 * scale }
    private var baseWidth: CGFloat { contentSize * scale + 2 * glowMargin }
    private var baseHeight: CGFloat { contentSize * scale + 2 * glowMargin }

    // MARK: 充电环几何

    private var ringWidth: CGFloat { 4 * scale }
    /// 背景圆角（环外缘需与之对齐）。
    private var ringCorner: CGFloat { 14 * scale }
    /// 充电环路径圆角：环整体内缩半个线宽后再描边，描边会向外扩半个线宽，
    /// 因此路径圆角取 `ringCorner - ringWidth/2`，外缘圆角才等于背景圆角。
    private var ringStrokeRadius: CGFloat { ringCorner - ringWidth / 2 }
    /// 充电环内壁圆角：路径圆角向内再收半个线宽。
    private var chargeInnerRadius: CGFloat { ringStrokeRadius - ringWidth / 2 }

    // MARK: 内环几何（CPU / RAM 合用）

    private var innerRingWidth: CGFloat { 3 * scale }
    /// 内环路径圆角：外壁圆角 = 路径圆角 + 内环宽/2，要等于充电环内壁圆角。
    private var innerRingRadius: CGFloat { chargeInnerRadius - innerRingWidth / 2 }
    /// 内环路径内缩：外壁内缩 = 内缩 - 内环宽/2，要等于充电环内壁内缩（ringWidth）。
    private var innerRingInset: CGFloat { ringWidth + innerRingWidth / 2 }

    private var progress: Double { Double(monitor.batteryPercent) / 100.0 }
    private var isCharging: Bool { monitor.isCharging }

    private var cpuColor: Color { Color(red: 0.25, green: 0.55, blue: 1.0) }
    private var ramColor: Color { Color(red: 0.75, green: 0.35, blue: 0.95) }

    /// 随电量平滑变化的环色（红 → 橙 → 黄绿 → 绿 → 青绿）。
    private var levelColor: Color { Self.levelColor(for: progress) }

    var body: some View {
        ZStack {
            // 半透明暗色底盘
            RoundedRectangle(cornerRadius: ringCorner)
                .fill(Color.black.opacity(0.32))

            // 充电环：底环 + 进度 + 流动高光。
            // 整体内缩半个线宽，避免描边一半被面板边缘裁切（否则环会显得断裂）。
            ZStack {
                RoundedRectangle(cornerRadius: ringStrokeRadius)
                    .stroke(Color.white.opacity(0.28), lineWidth: ringWidth)

                // 电量进度（随电量变色；充电时为静态外发光，环本身不做呼吸晃动）
                RoundedRectangle(cornerRadius: ringStrokeRadius)
                    .trim(from: 0, to: progress)
                    .stroke(
                        LinearGradient(colors: [levelColor, levelColor.opacity(0.55)],
                                       startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                    )
                    .shadow(color: isCharging ? levelColor.opacity(0.9) : Color.clear,
                            radius: 1.5 * scale)

                // 充电时沿环流动的高光
                if isCharging {
                    ChargingSweep(radius: ringStrokeRadius,
                                  lineWidth: ringWidth,
                                  scale: scale)
                }
            }
            .padding(ringWidth / 2)

            // 内环：一个整体，CPU 占上面半边环、RAM 占下面半边环，各按占用率填充。
            // 外壁与充电环内壁重合。
            ZStack {
                UpperFirstRing(cornerRadius: innerRingRadius)
                    .stroke(Color.white.opacity(0.15), lineWidth: innerRingWidth)

                // CPU：上半环，与 RAM 同基点（0.5）反向生长
                UpperFirstRing(cornerRadius: innerRingRadius)
                    .trim(from: 0.5 - 0.5 * CGFloat(monitor.cpuUsage), to: 0.5)
                    .stroke(cpuColor,
                            style: StrokeStyle(lineWidth: innerRingWidth, lineCap: .round))

                // RAM：下半环，自基点（0.5）正向生长
                UpperFirstRing(cornerRadius: innerRingRadius)
                    .trim(from: 0.5, to: 0.5 + 0.5 * CGFloat(monitor.memoryUsage))
                    .stroke(ramColor,
                            style: StrokeStyle(lineWidth: innerRingWidth, lineCap: .round))
            }
            .padding(innerRingInset)

            // 中间两行功率
            VStack(spacing: 1.5 * scale) {
                HStack(alignment: .firstTextBaseline, spacing: 1.5 * scale) {
                    Text(systemValueText)
                        .font(.system(size: 12 * scale, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .fixedSize()
                    Text("W")
                        .font(.system(size: 6.5 * scale, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                }

                HStack(alignment: .center, spacing: 2 * scale) {
                    Image(systemName: isCharging ? "bolt.fill" : "bolt.badge.clock")
                        .font(.system(size: 6.5 * scale, weight: .bold))
                        .foregroundColor(isCharging ? .yellow : .white.opacity(0.5))
                        // 充电时图标周期性发光：只让图标亮暗脉动，充电环保持静止不晃动
                        .shadow(color: isCharging
                                    ? Color.yellow.opacity(breathing ? 1.0 : 0.25)
                                    : Color.clear,
                                radius: (breathing ? 3.0 : 0.6) * scale)
                    Text(chargeValueText)
                        .font(.system(size: 8.5 * scale, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .fixedSize()
                    Text("W")
                        .font(.system(size: 6 * scale, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        // 四周留出透明余量，供外发光扩散（可见底盘仍为 contentSize×contentSize）
        .padding(glowMargin)
        .frame(width: baseWidth, height: baseHeight)
        // 电量变化时颜色平滑过渡；插拔电源时特效淡入淡出
        .animation(.easeInOut(duration: 0.8), value: monitor.batteryPercent)
        .animation(.easeInOut(duration: 0.3), value: isCharging)
        .onAppear { updateEffects() }
        .onChange(of: isCharging) { _ in updateEffects() }
    }

    /// 仅在充电时开启发光脉动（只驱动充电图标），不充电时不跑动画，避免空转徒增功耗。
    private func updateEffects() {
        if isCharging {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                breathing = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                breathing = false
            }
        }
    }

    // MARK: - 电量配色

    /// 电量 → 颜色：分段线性插值，0% 红 → 20% 橙红 → 40% 琥珀 → 60% 黄绿 → 80% 绿 → 100% 青绿。
    static func levelColor(for progress: Double) -> Color {
        let stops: [(pos: Double, rgb: (Double, Double, Double))] = [
            (0.00, (1.00, 0.23, 0.19)),
            (0.20, (1.00, 0.42, 0.18)),
            (0.40, (1.00, 0.75, 0.20)),
            (0.60, (0.62, 0.90, 0.25)),
            (0.80, (0.24, 0.88, 0.42)),
            (1.00, (0.16, 0.85, 0.62))
        ]
        let p = min(max(progress, 0), 1)
        for i in 0..<(stops.count - 1) {
            let a = stops[i]
            let b = stops[i + 1]
            if p <= b.pos {
                let span = b.pos - a.pos
                let t = span > 0 ? (p - a.pos) / span : 0
                return Color(red: a.rgb.0 + (b.rgb.0 - a.rgb.0) * t,
                             green: a.rgb.1 + (b.rgb.1 - a.rgb.1) * t,
                             blue: a.rgb.2 + (b.rgb.2 - a.rgb.2) * t)
            }
        }
        let last = stops[stops.count - 1].rgb
        return Color(red: last.0, green: last.1, blue: last.2)
    }

    // MARK: - 文本

    private var systemValueText: String {
        monitor.systemWatts > 0
            ? String(format: "%.1f", monitor.systemWatts)
            : "--"
    }

    private var chargeValueText: String {
        monitor.chargingWatts > 0
            ? String(format: "%.1f", monitor.chargingWatts)
            : (isCharging ? "…" : "0")
    }
}

/// 充电时沿环流动的高光。
///
/// 直接用「充电环自身的描边 + 角向渐变（AngularGradient）」来画，而不是另画一段弧：
/// 高光就是环的描边本身，因此必然与环严丝合缝地重合；
/// 且角向渐变天然首尾相接，不存在路径闭合点，也就不会出现闭合点处错位 / 长度变化的问题。
private struct ChargingSweep: View {
    var radius: CGFloat
    var lineWidth: CGFloat
    var scale: CGFloat

    /// 绕行一圈的时长（秒）。
    private let period: Double = 1.6

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
            let sweep = sweepAngle(at: context.date)
            RoundedRectangle(cornerRadius: radius)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white.opacity(0), location: 0.00),
                            .init(color: .white.opacity(0), location: 0.42),
                            .init(color: .white.opacity(0.85), location: 0.50),
                            .init(color: .white.opacity(0), location: 0.58),
                            .init(color: .white.opacity(0), location: 1.00)
                        ]),
                        center: .center,
                        startAngle: .degrees(sweep - 180),
                        endAngle: .degrees(sweep + 180)
                    ),
                    lineWidth: lineWidth
                )
                .blur(radius: 0.6 * scale)
        }
    }

    /// 当前高光所在的角向位置（度），由时钟直接求值，不经过 SwiftUI 隐式动画。
    private func sweepAngle(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return t / period * 360
    }
}

/// 圆角矩形环路径，但起点定在「左边缘中点」：
/// 先逆时针经左边缘上行、跨过顶边到右边缘中点（上半环 = trim 0…0.5），
/// 再经右边缘下行、沿底边回到起点（下半环 = trim 0.5…1）。
/// 起终点都落在左右边缘中点，因此上下两个半环长度相等，
/// CPU 取上半环、RAM 取下半环时即可干净地上下分区（用 RoundedRectangle 会按对角线分区）。
private struct UpperFirstRing: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        // 四分之一圆弧的三次贝塞尔近似系数，误差约 0.03%，肉眼与正圆角完全一致
        let k = r * 0.5522847498
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY
        let midY = rect.midY

        var p = Path()
        // 左边缘中点（上半环起点）
        p.move(to: CGPoint(x: minX, y: midY))
        // 左边缘上行至左上圆角起点
        p.addLine(to: CGPoint(x: minX, y: minY + r))
        // 左上圆角
        p.addCurve(to: CGPoint(x: minX + r, y: minY),
                   control1: CGPoint(x: minX, y: minY + r - k),
                   control2: CGPoint(x: minX + r - k, y: minY))
        // 顶边
        p.addLine(to: CGPoint(x: maxX - r, y: minY))
        // 右上圆角
        p.addCurve(to: CGPoint(x: maxX, y: minY + r),
                   control1: CGPoint(x: maxX - r + k, y: minY),
                   control2: CGPoint(x: maxX, y: minY + r - k))
        // 右边缘下行至中点（上半环终点 / 下半环起点）
        p.addLine(to: CGPoint(x: maxX, y: midY))
        // 右边缘下行至右下圆角起点
        p.addLine(to: CGPoint(x: maxX, y: maxY - r))
        // 右下圆角
        p.addCurve(to: CGPoint(x: maxX - r, y: maxY),
                   control1: CGPoint(x: maxX, y: maxY - r + k),
                   control2: CGPoint(x: maxX - r + k, y: maxY))
        // 底边（向左）
        p.addLine(to: CGPoint(x: minX + r, y: maxY))
        // 左下圆角
        p.addCurve(to: CGPoint(x: minX, y: maxY - r),
                   control1: CGPoint(x: minX + r - k, y: maxY),
                   control2: CGPoint(x: minX, y: maxY - r + k))
        // 左边缘上行回到起点
        p.closeSubpath()
        return p
    }
}
