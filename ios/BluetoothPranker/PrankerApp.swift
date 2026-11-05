import SwiftUI

@main
struct PrankerApp: App {
    @State private var ble = BLEManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(ble)
        }
    }
}
