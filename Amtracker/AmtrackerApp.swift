import SwiftUI

@main
struct AmtrackerApp: App {
    @StateObject private var live = LiveActivityManager.shared
    @StateObject private var store = TrainStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(live)
                .environmentObject(store)
                .task {
                    live.reattach()
                    #if DEBUG
                    // Debug aid: `-autostartActivity` starts a Live Activity for train 6 / TRU with no UI taps.
                    if ProcessInfo.processInfo.arguments.contains("-autostartActivity"), live.activity == nil {
                        await live.start(trainNumber: "6", stationCode: "TRU")
                    }
                    #endif
                }
        }
    }
}
