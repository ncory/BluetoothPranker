import SwiftUI

struct ContentView: View {
    @Environment(BLEManager.self) private var ble

    var body: some View {
        NavigationStack {
            Group {
                switch ble.phase {
                case .connected:
                    DashboardView()
                case .connecting(let name):
                    ConnectingView(name: name)
                default:
                    ScannerView()
                }
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { ble.lastError != nil }, set: { if !$0 { ble.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ble.lastError ?? "")
        }
    }
}

struct ScannerView: View {
    @Environment(BLEManager.self) private var ble

    var body: some View {
        List {
            switch ble.phase {
            case .bluetoothOff:
                ContentUnavailableView("Bluetooth is off", systemImage: "antenna.radiowaves.left.and.right.slash",
                                       description: Text("Turn on Bluetooth to find your Pranker."))
            case .unauthorized:
                ContentUnavailableView("Bluetooth permission needed", systemImage: "lock",
                                       description: Text("Allow Bluetooth for Pranker in Settings > Privacy & Security > Bluetooth."))
            case .unsupported:
                ContentUnavailableView("Bluetooth LE not supported", systemImage: "xmark.octagon",
                                       description: Text("This device can't talk to the Pranker."))
            default:
                Section {
                    if ble.devices.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for devices…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(ble.devices.sorted { $0.rssi > $1.rssi }) { d in
                        Button {
                            ble.connect(d)
                        } label: {
                            HStack {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(.tint)
                                    .frame(width: 30)
                                VStack(alignment: .leading) {
                                    Text(d.name).foregroundStyle(.primary)
                                    Text(d.id.uuidString.prefix(8)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                SignalBars(rssi: d.rssi)
                            }
                        }
                    }
                } header: {
                    Text("Nearby devices")
                } footer: {
                    Text("Power the Atom Echo from USB or a power bank and it shows up here within a few seconds.")
                }
            }
        }
        .navigationTitle("Pranker")
        .onAppear { if ble.phase == .idle { ble.startScan() } }
        .refreshable { ble.startScan() }
    }
}

struct ConnectingView: View {
    let name: String
    @Environment(BLEManager.self) private var ble

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Connecting to \(name)…").font(.headline)
            Text("Make sure it's powered on and nearby. If it just restarted (for example after pairing the target phone), it reconnects on its own.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose another device") { ble.disconnect() }
                .padding(.top)
        }
        .padding(32)
        .navigationTitle("Pranker")
    }
}
