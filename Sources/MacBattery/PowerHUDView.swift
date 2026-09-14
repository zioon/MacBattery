import SwiftUI

/// 置顶挂件 UI：外层矩形充电环（完整底环 + 电量进度）环绕中间两行功率；
/// 内层一个整体的内环承接 CPU / RAM，各占周长一半并按占用率填充；
/// 内环外壁与充电环内壁完全重合（几何上严丝合缝）。
/// 整体尺寸随 `scale` 缩放（基础宽高会随 scale 变化）。
struct PowerHUDView: View {

    @ObservedObject var monitor: PowerMonitor
    /// 缩放系数（0.8 / 1.0 / 1.3…）
    var scale: CGFloat = 1.0

    private var baseWidth: CGFloat { 58 }
    private var baseHeight: CGFloat { 58 }

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

    private var barColor: Color {
        let p = progress
        switch p {
        case ..<0.2: return Color(red: 1.0, green: 0.30, blue: 0.30)
        case ..<0.4: return Color(red: 1.0, green: 0.62, blue: 0.18)
        default:      return Color(red: 0.20, green: 0.86, blue: 0.45)
        }
    }

    private var cpuColor: Color { Color(red: 0.25, green: 0.55, blue: 1.0) }
    private var ramColor: Color { Color(red: 0.75, green: 0.35, blue: 0.95) }

    var body: some View {
        ZStack {
            // 半透明暗色底盘
            RoundedRectangle(cornerRadius: ringCorner)
                .fill(Color.black.opacity(0.32))

            // 充电环：完整底环 + 电量进度。
            // 整体内缩半个线宽，避免描边一半被面板边缘裁切（否则环会显得断裂）。
            ZStack {
                RoundedRectangle(cornerRadius: ringStrokeRadius)
                    .stroke(Color.white.opacity(0.28), lineWidth: ringWidth)

                RoundedRectangle(cornerRadius: ringStrokeRadius)
                    .trim(from: 0, to: progress)
                    .stroke(
                        LinearGradient(colors: [barColor, barColor.opacity(0.55)],
                                       startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                    )
            }
            .padding(ringWidth / 2)

            // 内环：一个整体，CPU 占前半环、RAM 占后半环，各按占用率填充。
            // 外壁与充电环内壁重合。
            ZStack {
                RoundedRectangle(cornerRadius: innerRingRadius)
                    .stroke(Color.white.opacity(0.15), lineWidth: innerRingWidth)

                // CPU：前半环
                RoundedRectangle(cornerRadius: innerRingRadius)
                    .trim(from: 0, to: 0.5 * CGFloat(monitor.cpuUsage))
                    .stroke(cpuColor,
                            style: StrokeStyle(lineWidth: innerRingWidth, lineCap: .round))

                // RAM：后半环
                RoundedRectangle(cornerRadius: innerRingRadius)
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
                    Image(systemName: monitor.isCharging ? "bolt.fill" : "bolt.badge.clock")
                        .font(.system(size: 6.5 * scale, weight: .bold))
                        .foregroundColor(monitor.isCharging ? .yellow : .white.opacity(0.5))
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
        .frame(width: baseWidth * scale, height: baseHeight * scale)
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
            : (monitor.isCharging ? "…" : "0")
    }
}