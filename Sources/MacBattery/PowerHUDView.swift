import SwiftUI

/// 置顶挂件的 UI：
/// 中央显示两行功率（整机 / 充电），外圈一圈圆环展示电量百分比。
struct PowerHUDView: View {

    @ObservedObject var monitor: PowerMonitor

    private var progress: Double {
        Double(monitor.batteryPercent) / 100.0
    }

    private var ringColor: Color {
        let p = progress
        switch p {
        case ..<0.2: return .red
        case ..<0.4: return .orange
        default:      return .green
        }
    }

    var body: some View {
        ZStack {
            // 背景托盘：半透明暗色圆角，便于在任意壁纸上看清内容。
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.35))

            // 电量圆环
            ZStack {
                // 底环
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 8)

                // 电量进度弧
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(
                            colors: [ringColor, ringColor.opacity(0.55)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                // 中央两行功率
                VStack(spacing: 4) {
                    HStack(spacing: 5) {
                        Text(monitor.systemWattsText)   // 整机功率
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                        Text("W")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    HStack(spacing: 5) {
                        Image(systemName: monitor.chargingWatts > 0 ? "bolt.fill" : "bolt.badge.clock")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.yellow)
                        Text(monitor.chargingText)      // 充电功率
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.85))
                        Text("W")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
            .padding(10)

            // 电量百分比角标（右下角小徽章）
            Text("\(monitor.batteryPercent)%")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(8)
        }
        .frame(width: 148, height: 184)
    }
}

// MARK: - 展示文本

private extension PowerMonitor {
    /// 整机功率文本：读不到时显示 "--"
    var systemWattsText: String {
        systemWatts > 0
            ? String(format: "%.1f", systemWatts)
            : "--"
    }

    /// 充电功率文本：未充电时显示 "0"
    var chargingText: String {
        chargingWatts > 0
            ? String(format: "%.1f", chargingWatts)
            : "0"
    }
}