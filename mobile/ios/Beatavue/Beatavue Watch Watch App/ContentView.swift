import SwiftUI

#Preview("Watch workout") {
    ContentView(workout: WatchWorkout())
}

/// Displays workout readings and controls on Apple Watch.
struct ContentView: View {
    /// Workout model supplying live readings and session state.
    let workout: WatchWorkout
    /// Whether the workout start confirmation is presented.
    @State private var confirmStart = false

    /// Builds the interface for this view.
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Beatavue").font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    WatchLiveReading(workout: workout, now: context.date)
                }
                WatchWorkoutControls(workout: workout, confirmStart: $confirmStart)
                if let error = workout.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                if workout.saved { Text("Saved to Apple Health").font(.caption) }
            }
            .padding(.horizontal)
        }
        .tint(.pink)
        .confirmationDialog("Start an Other workout?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start workout") { Task { await workout.start() } }
        } message: {
            Text("Records heart rate and mirrors it to iPhone. Stopping saves this workout to Apple Health. This is not continuous all-day monitoring.")
        }
    }
}

/// Displays the Watch heart rate, elapsed time, and connection status.
struct WatchLiveReading: View {
    /// Workout model supplying live readings and session state.
    let workout: WatchWorkout
    /// Current timestamp used to evaluate freshness and elapsed time.
    let now: Date

    /// Builds the interface for this view.
    var body: some View {
        VStack(spacing: 6) {
            Text(workout.phase.title).font(.caption)
            // Whether the workout is running or paused.
            let active = workout.phase == .running || workout.phase == .paused
            // Whether the latest measurement is missing or over 30 seconds old.
            let stale = workout.measuredAt.map { now.timeIntervalSince($0) > 30 } ?? true
            if let rate = workout.heartRate {
                Text("\(rate, format: .number.precision(.fractionLength(0)))")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(active && !stale ? Color.pink : Color.secondary)
                Text("bpm · last measurement").font(.caption2)
            } else if active {
                Text("Waiting for heart rate").font(.caption)
            }
            if active, stale, workout.measuredAt != nil {
                Text("Stale reading").font(.caption).foregroundStyle(.orange)
            }
            if let measured = workout.measuredAt {
                Text(measured, format: .dateTime.hour().minute().second()).font(.caption2)
            }
            // Elapsed time since the last update while the workout is running.
            let extra = workout.phase == .running ? max(0, now.timeIntervalSince(workout.elapsedUpdatedAt)) : 0
            Text(Duration.seconds(workout.elapsed + extra).formatted(.time(pattern: .minuteSecond)))
                .font(.title3.monospacedDigit())
            if active {
                Text(workout.phoneConnected ? "iPhone connected" : "iPhone disconnected")
                    .font(.caption2)
                    .foregroundStyle(workout.phoneConnected ? Color.secondary : Color.orange)
            }
        }
    }
}

/// Provides workout start, pause, save, and reconnect actions.
struct WatchWorkoutControls: View {
    /// Workout model supplying live readings and session state.
    let workout: WatchWorkout
    /// Whether the workout start confirmation is presented.
    @Binding var confirmStart: Bool

    /// Builds the interface for this view.
    var body: some View {
        if !workout.available {
            Text("Apple Health unavailable").font(.caption)
        } else if workout.phase == .running || workout.phase == .paused {
            Button(workout.phase == .paused ? "Resume workout" : "Pause workout") { workout.togglePause() }
            Button("Stop and save", role: .destructive) { workout.stop() }
            if !workout.phoneConnected {
                Button("Reconnect iPhone") { Task { await workout.reconnectPhone() } }
            }
        } else {
            Button("Start workout") { confirmStart = true }
                .disabled(workout.phase == .starting || workout.phase == .saving)
        }
    }
}
