import SwiftUI

struct DashboardView: View {
    @Environment(BLEManager.self) private var ble

    var body: some View {
        List {
            TargetSection()
            if ble.info?.hasTarget == true, ble.config != nil {
                PrankSection()
            }
            TestSection()
            if !ble.events.isEmpty {
                Section("Live events") {
                    ForEach(ble.events.prefix(8)) { EventRow(event: $0) }
                }
            }
            Section("Set up") {
                NavigationLink { EnrollView() } label: {
                    Label("Target phone", systemImage: "iphone.radiowaves.left.and.right")
                }
                NavigationLink { CalibrationView() } label: {
                    Label("Calibrate range", systemImage: "scope")
                }
                NavigationLink { SoundsView() } label: {
                    Label("Sounds", systemImage: "speaker.wave.3")
                }
                NavigationLink { SettingsView() } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                NavigationLink { LogView() } label: {
                    Label("Event log", systemImage: "list.bullet.rectangle")
                }
            }
            if let info = ble.info {
                Section {
                    LabeledContent("Firmware", value: info.firmware)
                    LabeledContent("Up for", value: formatDuration(info.uptimeSec))
                }
            }
        }
        .navigationTitle(ble.deviceName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { ble.disconnect() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}

private struct TargetSection: View {
    @Environment(BLEManager.self) private var ble

    var body: some View {
        Section("Target") {
            if ble.info?.hasTarget == false {
                NavigationLink { EnrollView() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("No target phone yet", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Pair his iPhone once so the device can recognize it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let s = ble.status {
                HStack(spacing: 14) {
                    Circle()
                        .fill(s.present ? Color.green : (s.hearingTarget ? Color.yellow : Color.gray))
                        .frame(width: 14, height: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.present ? "In range" : (s.hearingTarget ? "Nearby, not in range" : "Not detected"))
                            .font(.title3.bold())
                        Text(subtitle(s))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if s.hearingTarget, let sm = s.smoothed {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(Int(sm.rounded())) dBm").font(.headline.monospacedDigit())
                            SignalBars(rssi: Int(sm))
                        }
                    }
                }
                if s.hearingTarget, let sm = s.smoothed, let cfg = ble.config {
                    RangeGauge(value: sm, enter: cfg.enterRssi, exit: cfg.exitRssi)
                }
            } else {
                ProgressView()
            }
        }
    }

    private func subtitle(_ s: DeviceStatus) -> String {
        guard let ms = s.msSinceSeen else { return "Haven't heard his phone since power-on" }
        let ago = ms < 1500 ? "just now" : "\(formatDuration(ms / 1000)) ago"
        return "Last heard \(ago) · \(String(format: "%.1f", s.packetsPerSec)) packets/s"
    }
}

private struct PrankSection: View {
    @Environment(BLEManager.self) private var ble

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { ble.config?.armed ?? false },
                set: { v in ble.perform { try await ble.update { $0.armed = v } } })) {
                Label("Armed", systemImage: "bolt.fill")
            }
            if let s = ble.status {
                if s.armingRemaining > 0 {
                    Label("Silent for \(formatDuration(s.armingRemaining)) more (hide timer)", systemImage: "timer")
                        .foregroundStyle(.orange)
                }
                if s.cooldownRemaining > 0 {
                    Label("Cooldown: \(formatDuration(s.cooldownRemaining))", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                ble.perform { try await ble.restartHideTimer() }
            } label: {
                Label("Start hide timer (\(formatDuration(ble.config?.armDelaySec ?? 0)))", systemImage: "eye.slash")
            }
        } header: {
            Text("Prank")
        } footer: {
            Text("After power-on, or when you tap Start hide timer, the device stays silent for the hide time so you can stash it and walk away.")
        }
    }
}

private struct TestSection: View {
    @Environment(BLEManager.self) private var ble

    var body: some View {
        Section("Test on device") {
            HStack {
                ForEach(Clip.allCases) { clip in
                    Button {
                        ble.perform { try await ble.play(clip) }
                    } label: {
                        Label(clip.shortTitle, systemImage: clip.symbol)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button {
                    ble.perform { try await ble.stopSound() }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(ble.status?.playing != true)
            }
        }
    }
}
