import SwiftUI

/// 置顶挂件 UI：一个矩形充电环（stroke 边框）环绕中间两行功率；
/// CPU / RAM 作为两根细窄条贴在环内左右内壁，不额外占用面板面积。
/// 整体尺寸随 `scale` 缩放（基础宽高会随 scale 变化）。
struct PowerHUDView: View {

    @ObservedObject var monitor: PowerMonitor
    /// 缩放系数（0.8 / 1.0 / 1.3…）
    var scale: CGFloat = 1.0

    private var baseWidth: CGFloat { 208 }
    private var baseHeight: CGFloat { 64 }
    private var ringWidth: CGFloat { 5 * scale }
    private var ringCorner: CGFloat { 16 * scale }
    private var innerBarW: CGFloat { 7 * scale }
    private var fillMargin: CGFloat { 10 * scale }

    private var progress: Double { Double(monitor.batteryPercent) / 100.0 }

    private var barColor: Color {
        let p = progress
        switch p {
        case ..<0.2: return Color(red: 1.0, green: 0.30, blue: 0.30)
        case ..<0.4: return Color(red: 1.0, green: 0.62, blue: 0.18)
        default:      return Color(red: 0.20, green: 0.86, blue: 0.45)
        }
    }

    var body: some View {
        ZStack {
            // 半透明暗色底盘，保证在任意壁纸上可读
            RoundedRectangle(cornerRadius: ringCorner - 2)
                .fill(Color.black.opacity(0.30))

            // 矩形充电环：底环 + 进度弧
            RoundedRectangle(cornerRadius: ringCorner)
                .stroke(Color.white.opacity(0.16), lineWidth: ringWidth)

            RoundedRectangle(cornerRadius: ringCorner)
                .trim(from: 0, to: progress)
                .stroke(
                    LinearGradient(colors: [barColor, barColor.opacity(0.5)],
                                   startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(90))

            // 环内：两侧细窄条 + 中间两行功率
            HStack(spacing: 4 * scale) {
                // 左侧 CPU 窄条（贴内壁）
                InnerBar(label: "CPU", width: innerBarW, value: monitor.cpuUsage,
                         color: Color(red: 0.25, green: 0.55, blue: 1.0), scale: scale)
                Spacer(minLength: 2)

                // 中间两行功率
                VStack(spacing: 2 * scale) {
                    HStack(alignment: .firstTextBaseline, spacing: 2 * scale) {
                        Text(systemValueText)
                            .font(.system(size: 19 * scale, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .fixedSize()
                        Text("W")
                            .font(.system(size: 9 * scale, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    HStack(alignment: .center, spacing: 3 * scale) {
                        Image(systemName: monitor.isCharging ? "bolt.fill" : "bolt.badge.clock")
                            .font(.system(size: 8 * scale, weight: .bold))
                            .foregroundColor(monitor.isCharging ? .yellow : .white.opacity(0.5))
                        Text(chargeValueText)
                            .font(.system(size: 11 * scale, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                            .fixedSize()
                        Text("W")
                            .font(.system(size: 8 * scale, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }

                Spacer(minLength: 2)
                // 右侧 RAM 窄条（贴内壁）
                InnerBar(label: "RAM", width: innerBarW, value: monitor.memoryUsage,
                         color: Color(red: 0.75, green: 0.35, blue: 0.95), scale: scale)
            }
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 6 * scale)
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

/// 贴环内壁的细窄进度条：底槽 + 自底向上的填充，不显示文字。
private struct InnerBar: View {
    var label: String
    var width: CGFloat
    var value: Double
    var color: Color
    var scale: CGFloat

    private var corner: CGFloat { 3 * scale }

    var body: some View {
        VStack(spacing: 1 * scale) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: corner)
                    .fill(Color.white.opacity(0.15))
                RoundedRectangle(cornerRadius: corner)
                    .fill(color)
                    .frame(height: max(width * 4 * CGFloat(value), 1))
            }
            .frame(width: width, height: max(width * 6, 8) * scale)

            Text(label)
                .font(.system(size: 6 * scale, weight: .medium, design: .rounded))
                .foregroundColor(color.opacity(0.9))
        }
    }
}