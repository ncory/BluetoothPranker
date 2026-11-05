import SwiftUI

struct SettingsView: View {
    @Environment(BLEManager.self) private var ble
    @State private var draft: DeviceConfig?
    @State private var saving = false
    @State private var confirmReboot = false

    var body: some View {
        Form {
            if let c = Binding($draft) {
                content(c)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Settings")
        .onAppear { if draft == nil { draft = ble.config } }
        .onChange(of: ble.config) { old, new in
            // Follow device-side changes unless the user is mid-edit.
            if draft == old { draft = new }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(draft == nil || draft == ble.config || saving)
            }
        }
        .confirmationDialog("Reboot the device?", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("Reboot") { ble.perform { try await ble.reboot() } }
        } message: {
            Text("It restarts the hide timer and clears the event log. The app reconnects automatically.")
        }
    }

    @ViewBuilder
    private func content(_ c: Binding<DeviceConfig>) -> some View {
        Section {
            TextField("Bluetooth name", text: c.name)
                .autocorrectionDisabled()
            Toggle("Armed", isOn: c.armed)
            Toggle("Show presence on LED", isOn: c.led)
        } header: {
            Text("Device")
        } footer: {
            Text("Anyone scanning for Bluetooth devices can see the name, so pick something boring. Leave the LED off to stay stealthy (green = in range, red = away).")
        }

        Section {
            Toggle("Play on arrival", isOn: c.playEnter)
            Toggle("Play on departure", isOn: c.playLeave)
            VStack(alignment: .leading) {
                LabeledContent("Volume", value: "\(c.wrappedValue.volume)%")
                Slider(value: doubleBinding(c.volume), in: 0...100, step: 5)
            }
        } header: {
            Text("Sounds")
        }

        Section {
            ChanceControl(title: "On arrival", symbol: Clip.enter.symbol, value: c.enterChance)
            ChanceControl(title: "On departure", symbol: Clip.leave.symbol, value: c.leaveChance)
        } header: {
            Text("Randomness")
        } footer: {
            Text("The chance that a sound actually plays each time someone arrives or leaves. Below 100% it only happens some of the time, which makes it much harder to work out what's going on. Skipped events still show in the log.")
        }

        Section {
            Stepper("Hide timer: \(formatDuration(c.wrappedValue.armDelaySec))", value: c.armDelaySec, in: 0...1800, step: 15)
            Stepper("Cooldown: \(formatDuration(c.wrappedValue.cooldownSec))", value: c.cooldownSec, in: 0...3600, step: 10)
            Stepper("Gone after silence: \(formatDuration(c.wrappedValue.absenceSec))", value: c.absenceSec, in: 5...300, step: 5)
            Stepper("Weak signal must last: \(formatDuration(c.wrappedValue.exitHoldSec))", value: c.exitHoldSec, in: 0...60)
        } header: {
            Text("Timing")
        } footer: {
            Text("Hide timer: silence after power-on. Cooldown: minimum time between sounds for the same person. Gone after silence: counts as 'left' if a phone isn't heard this long; locked iPhones sometimes go quiet for a while, so don't set it too low. Weak signal must last: how long it must stay below the leave threshold.")
        }

        Section {
            Stepper("Enter at \(c.wrappedValue.enterRssi) dBm", value: c.enterRssi, in: -100...(-30))
            Stepper("Leave at \(c.wrappedValue.exitRssi) dBm", value: c.exitRssi, in: -105...(-35))
            VStack(alignment: .leading) {
                LabeledContent("Smoothing", value: String(format: "%.2f", c.wrappedValue.smoothing))
                Slider(value: c.smoothing, in: 0.05...1, step: 0.05)
            }
        } header: {
            Text("Detection")
        } footer: {
            Text("Use Calibrate to set these by walking around. Lower smoothing reacts more slowly but ignores spikes.")
        }

        Section {
            Button("Reboot device", role: .destructive) { confirmReboot = true }
        }
    }

    private func doubleBinding(_ b: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = Int($0.rounded()) })
    }

    private func save() {
        guard let d = draft else { return }
        saving = true
        Task {
            do {
                try await ble.saveConfig(d)
            } catch {
                ble.lastError = error.localizedDescription
            }
            saving = false
        }
    }
}

/// Percentage slider with quick presets, e.g. "plays 1 in 5 times".
struct ChanceControl: View {
    let title: String
    let symbol: String
    @Binding var value: Int
    private let presets = [100, 50, 25, 20, 10]

    private var meaning: String {
        switch value {
        case 100: return "Every time"
        case 0: return "Never"
        default:
            let oneIn = 100.0 / Double(value)
            if abs(oneIn - oneIn.rounded()) < 0.05 { return "About 1 in \(Int(oneIn.rounded())) times" }
            return "\(value)% of the time"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text("\(value)%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }), in: 0...100, step: 5)
            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { p in
                    Button("\(p)%") { value = p }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(value == p ? .accentColor : .secondary)
                }
                Spacer()
            }
            Text(meaning).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
