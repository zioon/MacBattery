import SwiftUI

/// 置顶挂件 UI：中间是电量横向内容（左侧电量填充条 + 紧贴两行功率），
/// 左右各一根 CPU / 内存占用竖向条。
/// 整体尺寸随 `scale` 缩放（基础宽高会随 scale 变化）。
struct PowerHUDView: View {

    @ObservedObject var monitor: PowerMonitor
    /// 缩放系数（0.8 / 1.0 / 1.3…）
    var scale: CGFloat = 1.0

    private var baseWidth: CGFloat { 296 }
    private var baseHeight: CGFloat { 96 }
    private var barWidth: CGFloat { 16 * scale }
    private var barHeight: CGFloat { 56 * scale }
    private var corner: CGFloat { 8 * scale }
    private var spacing: CGFloat { 8 * scale }

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
        HStack(alignment: .center, spacing: spacing) {
            // 左侧：CPU 竖向条
            MetricBar(label: "CPU",
                       value: monitor.cpuUsage,
                       barWidth: barWidth,
                       barHeight: barHeight,
                       corner: corner,
                       color: Color(red: 0.25, green: 0.55, blue: 1.0),
                       scale: scale)

            // 中间：电量 + 两行功率
            batteryBlock
                .frame(width: 196 * scale, height: 64 * scale)

            // 右侧：内存竖向条
            MetricBar(label: "RAM",
                       value: monitor.memoryUsage,
                       barWidth: barWidth,
                       barHeight: barHeight,
                       corner: corner,
                       color: Color(red: 0.75, green: 0.35, blue: 0.95),
                       scale: scale)
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 8 * scale)
        .background(
            RoundedRectangle(cornerRadius: 12 * scale)
                .fill(Color.black.opacity(0.32))
        )
        .frame(width: baseWidth * scale, height: baseHeight * scale, alignment: .center)
    }

    /// 电量条 + 紧贴的两行功率。
    private var batteryBlock: some View {
        HStack(spacing: 10 * scale) {
            // 电量矩形条：底槽 + 从底部向上的填充
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: corner)
                    .fill(Color.white.opacity(0.16))
                RoundedRectangle(cornerRadius: corner)
                    .fill(
                        LinearGradient(colors: [barColor, barColor.opacity(0.55)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(height: max(barHeight * CGFloat(progress), 1))
            }
            .frame(width: barWidth, height: barHeight)

            // 紧贴的两行功率
            VStack(alignment: .leading, spacing: 4 * scale) {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// 通用竖向指标条：顶部百分比数字，中部动态竖条，底部标签。
private struct MetricBar: View {
    var label: String
    var value: Double
    var barWidth: CGFloat
    var barHeight: CGFloat
    var corner: CGFloat
    var color: Color
    var scale: CGFloat

    private var percentText: String {
        String(format: "%.0f%%", (value * 100).rounded())
    }

    var body: some View {
        VStack(spacing: 2 * scale) {
            Text(percentText)
                .font(.system(size: 9 * scale, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: corner)
                    .fill(Color.white.opacity(0.16))
                RoundedRectangle(cornerRadius: corner)
                    .fill(color)
                    .frame(height: max(barHeight * CGFloat(value), 1))
            }
            .frame(width: barWidth, height: barHeight)

            Text(label)
                .font(.system(size: 8 * scale, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.55))
        }
    }
}