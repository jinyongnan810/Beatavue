import SwiftUI

@main
struct BeatavueApp: App {
    @State private var history = HistoryStore()
    @State private var live = PhoneWorkout()

    var body: some Scene {
        WindowGroup {
            ContentView(history: history, live: live)
        }
    }
}
