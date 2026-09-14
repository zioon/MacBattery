import SwiftUI

/// 置顶挂件 UI：外圈一条细圆环 = 电量百分比；
/// 圆心垂直排列 电量% / 整机功率 / 充电功率，紧凑贴住圆环。
/// 整体尺寸随 `scale` 缩放（基础边长会随 scale 变化）。
struct PowerHUDView: View {

    @ObservedObject var monitor: PowerMonitor
    /// 缩放系数（0.8 / 1.0 / 1.3…）
    var scale: CGFloat = 1.0

    private var baseSide: CGFloat { 90 }
    private var side: CGFloat { baseSide * scale }
    private var ringWidth: CGFloat { 6 * scale }
    private var pad: CGFloat { 3 * scale }

    private var progress: Double { Double(monitor.batteryPercent) / 100.0 }

    private var ringColor: Color {
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
            Circle()
                .fill(Color.black.opacity(0.32))

            // 电量圆环：底环 + 进度弧
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: ringWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(colors: [ringColor, ringColor.opacity(0.5)],
                                    center: .center),
                    style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            // 圆心内容：电量% + 两行功率，紧扣圆环
            VStack(spacing: 3 * scale) {
                Text("\(monitor.batteryPercent)%")
                    .font(.system(size: 11 * scale, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))

                // 第一行：整机功率
                HStack(alignment: .firstTextBaseline, spacing: 2 * scale) {
                    Text(systemValueText)
                        .font(.system(size: 22 * scale, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .fixedSize()
                    Text("W")
                        .font(.system(size: 10 * scale, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                }

                // 第二行：充电功率
                HStack(alignment: .center, spacing: 3 * scale) {
                    Image(systemName: monitor.isCharging ? "bolt.fill" : "bolt.badge.clock")
                        .font(.system(size: 9 * scale, weight: .bold))
                        .foregroundColor(monitor.isCharging ? .yellow : .white.opacity(0.5))
                    Text(chargeValueText)
                        .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .fixedSize()
                    Text("W")
                        .font(.system(size: 8 * scale, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(.top, 6 * scale)  // 给顶部进度弧 cap 留出空间
        }
        .frame(width: side, height: side)
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