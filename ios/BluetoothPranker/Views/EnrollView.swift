import SwiftUI

struct EnrollView: View {
    @Environment(BLEManager.self) private var ble
    @State private var confirmForget = false
    @State private var confirmStart = false

    private var hasTarget: Bool { ble.info?.hasTarget == true }
    private var name: String { ble.config?.name ?? ble.deviceName }

    var body: some View {
        List {
            Section {
                if hasTarget {
                    Label("Target phone enrolled", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label("No target phone enrolled", systemImage: "iphone.slash").foregroundStyle(.orange)
                }
                if let text = ble.info?.enrollResult.text {
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
                if hasTarget, let s = ble.status {
                    LabeledContent("Hearing it now", value: s.hearingTarget ? "Yes" : "No")
                }
            }

            Section("How it works") {
                Text("iPhones change their Bluetooth address every few minutes for privacy. When an iPhone pairs with a device, it shares a key that lets that device recognize it anyway. The Pranker briefly poses as a Bluetooth keyboard so his iPhone will pair with it from Settings, keeps the key, then switches back to normal mode with a different address so his phone never reconnects.")
                    .font(.callout)
            }

            Section("Steps") {
                Step(n: 1, text: "Tap **Start enrollment** below. The device restarts and its light pulses blue.")
                Step(n: 2, text: "On **his** iPhone (unlocked), go to **Settings › Bluetooth**. Under *Other Devices*, tap **\(name)**, then **Pair** if asked.")
                Step(n: 3, text: "The light turns **green** once it has the key, and the device restarts. Red means it failed or timed out (3 min). Press the device's button to cancel.")
                Step(n: 4, text: "Still on his iPhone, tap ⓘ next to **\(name)** › **Forget This Device** to clean up. Detection keeps working.")
                Step(n: 5, text: "Come back here. The app reconnects by itself and shows *Target phone enrolled*.")
            }

            Section {
                Button {
                    confirmStart = true
                } label: {
                    Label(hasTarget ? "Re-enroll a target phone" : "Start enrollment", systemImage: "link.badge.plus")
                }
            } footer: {
                Text("Tip: you can try the whole flow with your own iPhone first, then re-enroll his.")
            }

            if hasTarget {
                Section {
                    Button("Forget target phone", role: .destructive) { confirmForget = true }
                }
            }
        }
        .navigationTitle("Target phone")
        .confirmationDialog("Restart into pairing mode?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start enrollment") { ble.perform { try await ble.startEnrollment() } }
        } message: {
            Text("The app disconnects while the device waits up to 3 minutes for his iPhone to pair.")
        }
        .confirmationDialog("Forget the target phone?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { ble.perform { try await ble.forgetTarget() } }
        }
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
