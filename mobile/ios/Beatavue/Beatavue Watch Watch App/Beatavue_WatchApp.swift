import SwiftUI
import WatchKit

/// Creates the Watch app and installs workout recovery handling.
@main
struct Beatavue_Watch_Watch_AppApp: App {
    /// Application delegate that receives workout recovery callbacks.
    @WKApplicationDelegateAdaptor(WorkoutAppDelegate.self) private var delegate

    /// Creates the app’s main window scene.
    var body: some Scene {
        WindowGroup {
            ContentView(workout: WatchWorkout.shared)
        }
    }
}

/// Handles system requests to recover an active Watch workout.
final class WorkoutAppDelegate: NSObject, WKApplicationDelegate {
    /// Asks the shared workout model to recover the active HealthKit session.
    func handleActiveWorkoutRecovery() {
        Task { await WatchWorkout.shared.recover() }
    }
}
