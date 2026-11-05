import SwiftUI

@main
struct PrankerApp: App {
    @State private var ble = BLEManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(ble)
                .task {
                    // Launch with the "-demo" argument (Xcode scheme › Run › Arguments) to start in demo mode.
                    if ProcessInfo.processInfo.arguments.contains("-demo") { ble.startDemo() }
                }
        }
    }
}
