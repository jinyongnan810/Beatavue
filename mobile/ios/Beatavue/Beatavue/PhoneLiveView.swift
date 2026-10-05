import SwiftUI

struct PhoneLiveView: View {
    let workout: PhoneWorkout
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

struct PhoneLiveReading: View {
    let snapshot: WorkoutSnapshot?
    let disconnected: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot {
                let active = snapshot.state == .running || snapshot.state == .paused
                let connectionDelayed = active && now.timeIntervalSince(snapshot.sentAt) > 15
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
