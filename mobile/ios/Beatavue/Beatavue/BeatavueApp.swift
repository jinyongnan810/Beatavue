import SwiftUI

/// Creates the iPhone app and its shared history and workout stores.
@main
struct BeatavueApp: App {
    @UIApplicationDelegateAdaptor(CloudAppDelegate.self) private var appDelegate
    /// Shared store for cached and refreshed health history.
    @State private var history = HistoryStore()
    /// Shared receiver for mirrored Watch workouts.
    @State private var live = PhoneWorkout()

    /// Creates the app’s main window scene.
    var body: some Scene {
        WindowGroup {
            ContentView(history: history, live: live)
        }
    }
}
