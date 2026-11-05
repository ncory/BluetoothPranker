import SwiftUI

/// Pairs a new iPhone with the device (enrollment).
struct AddTargetView: View {
    @Environment(BLEManager.self) private var ble
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmStart = false
    @FocusState private var nameFocused: Bool

    private var deviceName: String { ble.config?.name ?? ble.deviceName }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            Section {
                TextField("Name, e.g. Alex or Me (test)", text: $name)
                    .focused($nameFocused)
                    .submitLabel(.done)
            } header: {
                Text("Who is this phone?")
            } footer: {
                if let text = ble.info?.enrollResult.text { Text(text) }
            }

            Section("How it works") {
                Text("iPhones change their Bluetooth address every few minutes for privacy. When an iPhone pairs with a device, it shares a key that lets that device recognize it anyway. The Pranker briefly poses as a Bluetooth keyboard so the phone will pair with it from Settings, keeps the key, then switches back to normal mode with a different address so the phone never reconnects.")
                    .font(.callout)
            }

            Section("Steps") {
                Step(n: 1, text: "Enter a name above and tap **Start pairing**. The device restarts and its light pulses blue.")
                Step(n: 2, text: "On the **target** iPhone (unlocked), go to **Settings › Bluetooth**. Under *Other Devices*, tap **\(deviceName)**, then **Pair** if asked.")
                Step(n: 3, text: "The light turns **green** when it has the key, then the device restarts. Red means it failed or timed out after 3 minutes. Press the device's button to cancel.")
                Step(n: 4, text: "On that iPhone, tap ⓘ next to **\(deviceName)** › **Forget This Device** to clean up. Detection keeps working.")
                Step(n: 5, text: "Come back here. The app reconnects by itself and the new target appears.")
            }

            Section {
                Button {
                    confirmStart = true
                } label: {
                    Label("Start pairing", systemImage: "link.badge.plus")
                }
                .disabled(trimmed.isEmpty)
            } footer: {
                Text("Add your own iPhone first as a test target: you can walk in and out of range with it and hear the sounds. Pause or remove it before the real prank. Pairing a phone that's already a target just renames it.")
            }
        }
        .navigationTitle("Add target")
        .onAppear { nameFocused = ble.targets.isEmpty }
        .confirmationDialog("Restart into pairing mode?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start pairing") {
                let n = String(trimmed.prefix(16))
                ble.perform {
                    try await ble.startEnrollment(name: n)
                    dismiss()
                }
            }
        } message: {
            Text("The app disconnects while the device waits up to 3 minutes for the phone to pair.")
        }
    }
}

struct TargetDetailView: View {
    let targetID: Int
    @Environment(BLEManager.self) private var ble
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmRemove = false
    @State private var clipFlow = ClipFlow()

    private var target: TargetInfo? { ble.targets.first { $0.id == targetID } }

    var body: some View {
        List {
            if let t = target {
                Section {
                    TargetRow(target: t, status: ble.targetStatus[t.id])
                    if t.enabled, let s = ble.targetStatus[t.id], s.hearing, let sm = s.smoothed, let cfg = ble.config {
                        RangeGauge(value: sm, enter: cfg.enterRssi, exit: cfg.exitRssi)
                    }
                    if t.enabled, let s = ble.targetStatus[t.id], let ms = s.msSinceSeen {
                        LabeledContent("Last heard", value: ms < 1500 ? "just now" : "\(formatDuration(ms / 1000)) ago")
                        LabeledContent("Packets per second", value: String(format: "%.1f", s.packetsPerSec))
                    }
                    Toggle("Enabled", isOn: Binding(
                        get: { t.enabled },
                        set: { v in ble.perform { try await ble.setTarget(t.id, enabled: v) } }))
                } footer: {
                    Text("Pause a target to stop it from triggering without forgetting the phone.")
                }

                Section("Name") {
                    TextField("Name", text: $name)
                        .submitLabel(.done)
                        .onSubmit(rename)
                    if name != t.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Save name", action: rename)
                    }
                }

                Section {
                    ForEach(Clip.allCases) { kind in
                        ClipSlotRow(slot: ClipSlot(targetID: t.id, kind: kind), bytes: t.clipBytes(kind),
                                    flow: clipFlow)
                    }
                } header: {
                    Text("Sounds for \(t.name)")
                } footer: {
                    Text("Optional. Without a custom sound, \(t.name) gets the default sounds.")
                }

                Section {
                    NavigationLink {
                        CalibrationView(initialSource: .target(t.id))
                    } label: {
                        Label("Calibrate with this phone", systemImage: "scope")
                    }
                }

                Section {
                    Button("Remove target", role: .destructive) { confirmRemove = true }
                }
            } else {
                ContentUnavailableView("Target removed", systemImage: "person.slash")
            }
        }
        .navigationTitle(target?.name ?? "Target")
        .clipFlowHost(clipFlow)
        .onAppear { name = target?.name ?? "" }
        .confirmationDialog("Remove \(target?.name ?? "this target")?", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                ble.perform {
                    try await ble.removeTarget(targetID)
                    dismiss()
                }
            }
        } message: {
            Text("The device forgets this phone and its custom sounds. You can pair it again later.")
        }
    }

    private func rename() {
        let n = String(name.trimmingCharacters(in: .whitespaces).prefix(16))
        guard !n.isEmpty, n != target?.name else { return }
        ble.perform { try await ble.renameTarget(targetID, to: n) }
    }
}

private struct Step: View {
    let n: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
        }
        .padding(.vertical, 2)
    }
}
