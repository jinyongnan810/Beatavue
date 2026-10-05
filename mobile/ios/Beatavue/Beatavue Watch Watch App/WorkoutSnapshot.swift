import Foundation

// Keep this wire format identical in both targets; no HealthKit samples are sent to a server.
nonisolated struct WorkoutSnapshot: Codable, Equatable, Sendable {
    var sessionID: UUID
    var state: WorkoutPhase
    var heartRate: Double?
    var measuredAt: Date?
    var startedAt: Date?
    var elapsed: TimeInterval
    var sentAt: Date
}

nonisolated enum WorkoutPhase: String, Codable, Sendable {
    case idle, starting, running, paused, saving, ended, failed
    var title: LocalizedStringResource {
        switch self {
        case .idle: "Start a workout on Apple Watch"
        case .starting: "Starting workout"
        case .running: "Workout running"
        case .paused: "Workout paused"
        case .saving: "Saving workout"
        case .ended: "Workout ended"
        case .failed: "Workout failed"
        }
    }
}
