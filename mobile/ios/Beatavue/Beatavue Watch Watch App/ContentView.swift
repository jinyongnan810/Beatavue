import SwiftUI

struct ContentView: View {
    let workout: WatchWorkout
    @State private var confirmStart = false

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

struct WatchLiveReading: View {
    let workout: WatchWorkout
    let now: Date

    var body: some View {
        VStack(spacing: 6) {
            Text(workout.phase.title).font(.caption)
            let active = workout.phase == .running || workout.phase == .paused
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

struct WatchWorkoutControls: View {
    let workout: WatchWorkout
    @Binding var confirmStart: Bool

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
