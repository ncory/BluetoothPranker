import SwiftUI

struct LogView: View {
    @Environment(BLEManager.self) private var ble

    var body: some View {
        List {
            if ble.log.isEmpty {
                ContentUnavailableView("No events yet", systemImage: "clock",
                                       description: Text("Arrivals and departures since the device was powered on show up here."))
            } else {
                Section {
                    ForEach(ble.log) { e in
                        HStack {
                            Image(systemName: e.enter ? Clip.enter.symbol : Clip.leave.symbol)
                                .foregroundStyle(e.enter ? .green : .orange)
                                .frame(width: 28)
                            VStack(alignment: .leading) {
                                Text("\(ble.targetName(e.targetID)) \(e.enter ? "arrived" : "left")")
                                Text(e.played ? "Sound played" : "Silent")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(e.date, format: .dateTime.hour().minute().second())
                                    .monospacedDigit()
                                Text(e.date, format: .dateTime.weekday().day().month())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("The device keeps the last 20 events in memory. They're lost when it loses power. Times are approximate.")
                }
            }
        }
        .navigationTitle("Event log")
        .refreshable { ble.refreshLog() }
        .onAppear { ble.refreshLog() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { ble.perform { try await ble.clearLog() } }
                    .disabled(ble.log.isEmpty)
            }
        }
    }
}
