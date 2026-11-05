import SwiftUI

struct SignalBars: View {
    let rssi: Int

    private var level: Int {
        switch rssi {
        case (-60)...: return 4
        case (-70)...: return 3
        case (-80)...: return 2
        case (-90)...: return 1
        default: return 0
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < level ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(5 + i * 4))
            }
        }
        .accessibilityLabel("Signal \(rssi) dBm")
    }
}

/// A horizontal scale showing where the current signal sits relative to the
/// enter and leave thresholds.
struct RangeGauge: View {
    let value: Double
    let enter: Int
    let exit: Int
    private let lo = -100.0, hi = -30.0

    private func x(_ v: Double, _ w: CGFloat) -> CGFloat {
        CGFloat((min(max(v, lo), hi) - lo) / (hi - lo)) * w
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 8)
                    Capsule().fill(Color.green.opacity(0.35))
                        .frame(width: w - x(Double(enter), w), height: 8)
                        .offset(x: x(Double(enter), w))
                    Capsule().fill(Color.red.opacity(0.25))
                        .frame(width: x(Double(exit), w), height: 8)
                    Circle().fill(Color.primary)
                        .frame(width: 14, height: 14)
                        .offset(x: x(value, w) - 7)
                }
                .frame(height: 14)
            }
            .frame(height: 14)
            HStack {
                Text("far").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("leave ≤ \(exit) · enter ≥ \(enter)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("close").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct EventRow: View {
    let event: DeviceEvent

    var body: some View {
        HStack {
            Image(systemName: event.enter ? Clip.enter.symbol : Clip.leave.symbol)
                .foregroundStyle(event.enter ? .green : .orange)
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(event.enter ? "Arrived" : "Left")
                Text(event.played ? "Played the \(event.enter ? "enter" : "leave") sound"
                                  : "Silent: \(event.reasonText ?? "skipped")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(event.date, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

func formatDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds) s" }
    if seconds < 3600 { return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s" }
    let h = seconds / 3600, m = (seconds % 3600) / 60
    return m == 0 ? "\(h) h" : "\(h) h \(m) min"
}

func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

/// Approximate length of a 16 kHz mono 16-bit clip.
func clipSeconds(_ bytes: Int) -> Double {
    Double(max(0, bytes - 44)) / 32_000
}
