import SwiftUI

#Preview("Live workout") {
    PhoneLiveView(workout: PhoneWorkout())
}

#Preview("Running workout reading") {
    /// Current timestamp used to evaluate freshness and elapsed time.
    let now = Date()
    PhoneLiveReading(
        snapshot: WorkoutSnapshot(
            sessionID: UUID(), state: .running, heartRate: 124,
            measuredAt: now.addingTimeInterval(-5),
            startedAt: now.addingTimeInterval(-600), elapsed: 600, sentAt: now
        ),
        disconnected: false, now: now
    )
    .padding()
}

/// Displays the mirrored Watch workout and connection status.
struct PhoneLiveView: View {
    /// Workout model supplying live readings and session state.
    let workout: PhoneWorkout
    /// Builds the interface for this view.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        PhoneLiveReading(snapshot: workout.snapshot, disconnected: workout.disconnected, now: context.date)
                    }
                    Text(workout.watchStatus).font(.subheadline)
                    if let error = workout.error { Text(error).foregroundStyle(.orange) }
                    Text("Start, pause, or stop an Other workout in Beatavue on your Apple Watch. Stopping saves it to Apple Health.")
                    Text("Updates follow the sensor and system cadence. A reading becomes stale after 30 seconds. Watch history can appear later after synchronization.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Live workout")
            .onAppear { workout.updateWatchStatus() }
        }
    }
}

/// Displays the latest workout reading and its freshness.
struct PhoneLiveReading: View {
    /// Most recent mirrored workout state and measurement.
    let snapshot: WorkoutSnapshot?
    /// Whether the mirrored Watch session has disconnected.
    let disconnected: Bool
    /// Current timestamp used to evaluate freshness and elapsed time.
    let now: Date

    /// Builds the interface for this view.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot {
                // Whether the workout is running or paused.
                let active = snapshot.state == .running || snapshot.state == .paused
                // Whether an active workout has gone over 15 seconds without an update.
                let connectionDelayed = active && now.timeIntervalSince(snapshot.sentAt) > 15
                // Whether the latest measurement is missing or over 30 seconds old.
                let stale = snapshot.measuredAt.map { now.timeIntervalSince($0) > 30 } ?? true
                Text(snapshot.state.title).font(.headline)
                if disconnected || connectionDelayed {
                    Label("Watch disconnected or updates delayed", systemImage: "wifi.slash").foregroundStyle(.orange)
                    Text("Use Reconnect iPhone on Apple Watch while the workout is active.")
                        .font(.caption)
                } else if snapshot.state == .running, snapshot.heartRate == nil {
                    Text("Waiting for a heart-rate measurement")
                } else if active, stale {
                    Label("Stale reading — waiting for a new measurement", systemImage: "clock").foregroundStyle(.orange)
                }
                if let value = snapshot.heartRate {
                    Text("Last measurement").font(.caption).foregroundStyle(.secondary)
                    Text("\(value, format: .number.precision(.fractionLength(0))) bpm")
                        .font(.largeTitle.bold())
                        .foregroundStyle(stale || disconnected || connectionDelayed || !active ? Color.secondary : Color.pink)
                }
                if let measured = snapshot.measuredAt {
                    Text(measured, format: .dateTime.year().month().day().hour().minute().second())
                }
                if let started = snapshot.startedAt {
                    Text("Started \(started, format: .dateTime.month().day().hour().minute())")
                        .font(.caption)
                }
                // Elapsed time since the last update while the workout is running.
                let extra = snapshot.state == .running && !disconnected && !connectionDelayed ? max(0, now.timeIntervalSince(snapshot.sentAt)) : 0
                Text("Active time: \(Duration.seconds(snapshot.elapsed + extra).formatted(.time(pattern: .minuteSecond)))")
                    .monospacedDigit()
            } else {
                Text("Waiting for Apple Watch").font(.title2.bold())
                if disconnected { Text("Watch disconnected").foregroundStyle(.orange) }
                Text("Your workout heart rate and measurement time will appear here when the session is mirrored.")
            }
        }
    }
}
