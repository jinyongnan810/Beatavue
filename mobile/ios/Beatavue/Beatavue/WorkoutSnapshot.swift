import Foundation

// Keep this wire format identical in both targets; no HealthKit samples are sent to a server.
nonisolated struct WorkoutSnapshot: Codable, Equatable, Sendable {
    /// Identifier shared by updates from the same workout session.
    var sessionID: UUID
    /// Workout lifecycle state carried by this update.
    var state: WorkoutPhase
    /// Latest measured heart rate in beats per minute.
    var heartRate: Double?
    /// Timestamp of the latest heart-rate measurement.
    var measuredAt: Date?
    /// Workout start timestamp, when available.
    var startedAt: Date?
    /// Active workout duration reported by HealthKit, excluding pauses.
    var elapsed: TimeInterval
    /// Timestamp when this workout update was prepared.
    var sentAt: Date
}

/// Defines the workout lifecycle states shared by both devices.
nonisolated enum WorkoutPhase: String, Codable, Sendable {
    case idle, starting, running, paused, saving, ended, failed
    /// Localized label for this option or workout state.
    var title: LocalizedStringResource {
        switch self {
        case .idle: "Ready"
        case .starting: "Starting…"
        case .running: "Running"
        case .paused: "Paused"
        case .saving: "Saving…"
        case .ended: "Ended"
        case .failed: "Workout failed"
        }
    }
}
