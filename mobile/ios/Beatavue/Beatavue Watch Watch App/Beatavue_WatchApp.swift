import SwiftUI
import WatchKit

@main
struct Beatavue_Watch_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(WorkoutAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView(workout: WatchWorkout.shared)
        }
    }
}

final class WorkoutAppDelegate: NSObject, WKApplicationDelegate {
    func handleActiveWorkoutRecovery() {
        Task { await WatchWorkout.shared.recover() }
    }
}
