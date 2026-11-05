import SwiftUI

struct DashboardView: View {
    @Environment(BLEManager.self) private var ble

    var body: some View {
        List {
            TargetsSection()
            if !ble.targets.isEmpty, ble.config != nil {
                PrankSection()
            }
            TestSection()
            if !ble.events.isEmpty {
                Section("Live events") {
                    ForEach(ble.events.prefix(8)) { EventRow(event: $0) }
                }
            }
            Section("Set up") {
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
                    if ble.isDemo {
                        Text("Demo mode: simulated device, nothing is sent over Bluetooth.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(ble.deviceName)
        .sensoryFeedback(.impact, trigger: ble.events.first?.id)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(ble.isDemo ? "Exit demo" : "Disconnect", systemImage: "xmark.circle", role: .destructive) {
                        ble.disconnect()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}

private struct TargetsSection: View {
    @Environment(BLEManager.self) private var ble

    var body: some View {
        Section {
            if ble.targets.isEmpty {
                NavigationLink { AddTargetView() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("No target phones yet", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Pair an iPhone once so the device can recognize it. Start with your own to test.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(ble.targets) { t in
                    NavigationLink { TargetDetailView(targetID: t.id) } label: {
                        TargetRow(target: t, status: ble.targetStatus[t.id])
                    }
                }
                if ble.targets.count < (ble.info?.maxTargets ?? 8) {
                    NavigationLink { AddTargetView() } label: {
                        Label("Add target", systemImage: "plus.circle")
                    }
                }
            }
        } header: {
            Text("Targets")
        }
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
            if let cfg = ble.config, cfg.enterChance < 100 || cfg.leaveChance < 100 {
                Label("Random: \(cfg.enterChance)% of arrivals, \(cfg.leaveChance)% of departures", systemImage: "dice")
                    .foregroundStyle(.secondary)
            }
            if let wait = ble.status?.armingRemaining, wait > 0 {
                Label("Silent for \(formatDuration(wait)) more (hide timer)", systemImage: "timer")
                    .foregroundStyle(.orange)
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
                        ble.perform { try await ble.play(ClipSlot(targetID: nil, kind: clip)) }
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
