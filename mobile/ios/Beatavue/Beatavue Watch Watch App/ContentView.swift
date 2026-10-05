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
                if workout.saved { Text("Saved to Health").font(.caption) }
            }
            .padding(.horizontal)
        }
        .tint(.pink)
        .confirmationDialog("Start workout?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start workout") { Task { await workout.start() } }
        } message: {
            Text("Records heart rate. Stop to save to Health.")
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
                Text("bpm").font(.caption2)
            } else if active {
                Text("Measuring…").font(.caption)
            }
            if active, stale, workout.measuredAt != nil {
                Text("Reading over 30s old").font(.caption).foregroundStyle(.orange)
            }
            if let measured = workout.measuredAt {
                Text(measured, format: .dateTime.hour().minute().second()).font(.caption2)
            }
            // Elapsed time since the last update while the workout is running.
            let extra = workout.phase == .running ? max(0, now.timeIntervalSince(workout.elapsedUpdatedAt)) : 0
            Text(Duration.seconds(workout.elapsed + extra).formatted(.time(pattern: .minuteSecond)))
                .font(.title3.monospacedDigit())
            if active {
                Label(workout.phoneConnected ? "iPhone connected" : "iPhone disconnected", systemImage: workout.phoneConnected ? "iphone" : "iphone.slash")
                    .labelStyle(.iconOnly)
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
            Button(workout.phase == .paused ? "Resume workout" : "Pause workout", systemImage: workout.phase == .paused ? "play.fill" : "pause.fill") { workout.togglePause() }
                .labelStyle(.iconOnly)
            Button("Stop and save", systemImage: "stop.fill", role: .destructive) { workout.stop() }
                .labelStyle(.iconOnly)
            if !workout.phoneConnected {
                Button("Reconnect", systemImage: "iphone") { Task { await workout.reconnectPhone() } }
            }
        } else {
            Button("Start workout") { confirmStart = true }
                .disabled(workout.phase == .starting || workout.phase == .saving)
        }
    }
}
