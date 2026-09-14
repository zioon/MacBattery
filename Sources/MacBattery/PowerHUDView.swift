import SwiftUI

/// 置顶挂件 UI：矩形充电环（完整底环 + 电量进度）环绕中间两行功率；
/// CPU / RAM 数据条以 overlay 方式紧贴环内左右内壁，不参与布局、不额外占空间。
/// 整体尺寸随 `scale` 缩放（基础宽高会随 scale 变化）。
struct PowerHUDView: View {

    @ObservedObject var monitor: PowerMonitor
    /// 缩放系数（0.8 / 1.0 / 1.3…）
    var scale: CGFloat = 1.0

    private var baseWidth: CGFloat { 58 }
    private var baseHeight: CGFloat { 58 }
    private var ringWidth: CGFloat { 4 * scale }
    private var ringCorner: CGFloat { 14 * scale }

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
                RoundedRectangle(cornerRadius: ringCorner)
                    .stroke(Color.white.opacity(0.28), lineWidth: ringWidth)

                RoundedRectangle(cornerRadius: ringCorner)
                    .trim(from: 0, to: progress)
                    .stroke(
                        LinearGradient(colors: [barColor, barColor.opacity(0.55)],
                                       startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                    )
            }
            .padding(ringWidth / 2)

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

            // 左侧 CPU 数据条：紧贴环内左壁
            InnerBar(label: "CPU", value: monitor.cpuUsage,
                     color: cpuColor, scale: scale, labelAlignment: .leading)
                .padding(.leading, ringWidth + 1.5 * scale)
                .padding(.vertical, ringWidth + 3 * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            // 右侧 RAM 数据条：紧贴环内右壁
            InnerBar(label: "RAM", value: monitor.memoryUsage,
                     color: ramColor, scale: scale, labelAlignment: .trailing)
                .padding(.trailing, ringWidth + 1.5 * scale)
                .padding(.vertical, ringWidth + 3 * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
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

/// 紧贴环内壁的竖向数据条：细条 + 自底向上的填充，条内侧跟一行极小标签。
private struct InnerBar: View {
    var label: String
    var value: Double
    var color: Color
    var scale: CGFloat
    /// 标签相对细条的对齐方向（左侧条用 .leading，右侧条用 .trailing）。
    var labelAlignment: HorizontalAlignment

    private var width: CGFloat { 4 * scale }

    var body: some View {
        VStack(alignment: labelAlignment, spacing: 1.5 * scale) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: width / 2)
                        .fill(Color.white.opacity(0.15))
                    RoundedRectangle(cornerRadius: width / 2)
                        .fill(color)
                        .frame(height: max(geo.size.height * CGFloat(value), 1))
                }
            }
            .frame(width: width)

            Text(label)
                .font(.system(size: 5 * scale, weight: .semibold, design: .rounded))
                .foregroundColor(color)
                .fixedSize()
        }
    }
}