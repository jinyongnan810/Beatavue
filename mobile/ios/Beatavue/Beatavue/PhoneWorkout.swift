import Foundation
import HealthKit
import Observation
import WatchConnectivity

/// Receives mirrored Watch workouts and tracks companion app status.
@MainActor @Observable
final class PhoneWorkout: NSObject {
    /// Most recent mirrored workout state and measurement.
    private(set) var snapshot: WorkoutSnapshot?
    /// Whether the mirrored Watch session has disconnected.
    private(set) var disconnected = false
    /// Localized status of the paired Watch and its app installation.
    private(set) var watchStatus: LocalizedStringResource = "Checking Apple Watch"
    /// Most recent workout or connection error shown to the user.
    private(set) var error: String?
    /// HealthKit store used to manage workout sessions and permissions.
    @ObservationIgnored private let store = HKHealthStore()
    /// HealthKit workout session managed by this model.
    @ObservationIgnored private var session: HKWorkoutSession?
    /// WatchConnectivity session used to inspect companion app status.
    @ObservationIgnored private var connectivity: WCSession?

    /// Installs workout mirroring and companion connectivity handlers.
    override init() {
        super.init()
        // Install at launch so HealthKit can wake the app with a mirrored session.
        store.workoutSessionMirroringStartHandler = { [weak self] session in
            guard let self else { return }
            Task { @MainActor in self.attach(session) }
        }
        if WCSession.isSupported() {
            connectivity = .default
            connectivity?.delegate = self
            connectivity?.activate()
        } else {
            watchStatus = "Apple Watch connectivity unavailable"
        }
    }

    /// Updates the paired Watch and companion app installation status.
    func updateWatchStatus() {
        guard let connectivity else { return }
        if connectivity.activationState != .activated {
            watchStatus = "Checking Apple Watch"
        } else if !connectivity.isPaired {
            watchStatus = "No paired Apple Watch"
        } else if !connectivity.isWatchAppInstalled {
            watchStatus = "Install Beatavue on Apple Watch"
        } else {
            // WCSession reachability describes its messaging transport, not HealthKit mirroring.
            watchStatus = "Beatavue is installed on your paired Apple Watch. Start a workout there."
        }
    }

    /// Attaches a mirrored workout session and clears previous connection errors.
    private func attach(_ session: HKWorkoutSession) {
        self.session?.delegate = nil
        self.session = session
        session.delegate = self
        // Current workout lifecycle state.
        let phase: WorkoutPhase = session.state == .paused ? .paused : .running
        snapshot = WorkoutSnapshot(sessionID: UUID(), state: phase, heartRate: nil,
                                   measuredAt: nil, startedAt: session.startDate, elapsed: 0, sentAt: Date())
        disconnected = false
        error = nil
    }

    /// Validates incoming workout snapshots and accepts updates in timestamp order.
    private func receive(_ messages: [Data], from session: HKWorkoutSession) {
        guard self.session === session else { return }
        for data in messages {
            do {
                // Decoded Watch update awaiting validation and timestamp ordering.
                let incoming = try JSONDecoder().decode(WorkoutSnapshot.self, from: data)
                guard incoming.elapsed.isFinite, incoming.elapsed >= 0,
                      incoming.heartRate.map({ $0.isFinite && $0 > 0 }) ?? true,
                      incoming.measuredAt.map({ $0 <= incoming.sentAt }) ?? true else { continue }
                if let current = snapshot, current.sentAt > incoming.sentAt { continue }
                snapshot = incoming
                disconnected = false
                error = nil
            } catch {
                self.error = "Could not read an update from Apple Watch."
            }
        }
    }
}

extension PhoneWorkout: HKWorkoutSessionDelegate {
    /// Applies workout lifecycle changes on the main actor.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from _: HKWorkoutSessionState, date _: Date)
    {
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            if toState == .ended {
                self.snapshot?.state = .ended
                self.session = nil
                self.disconnected = false
            } else if toState == .paused {
                self.snapshot?.state = .paused
            }
        }
    }

    /// Handles a workout session failure on the main actor.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.error = error.localizedDescription
            self.disconnected = true
        }
    }

    /// Passes remote workout updates to the main actor for validation.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        Task { @MainActor in self.receive(data, from: workoutSession) }
    }

    /// Updates connection state when the remote workout device disconnects.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.disconnected = self.snapshot?.state != .ended
            self.error = error?.localizedDescription
            self.session = nil
        }
    }
}

extension PhoneWorkout: WCSessionDelegate {
    /// Refreshes companion app status after WatchConnectivity activation completes.
    nonisolated func session(_: WCSession, activationDidCompleteWith _: WCSessionActivationState, error _: Error?) {
        Task { @MainActor in self.updateWatchStatus() }
    }

    /// Receives the inactive callback without changing workout mirroring.
    nonisolated func sessionDidBecomeInactive(_: WCSession) {}
    /// Reactivates WatchConnectivity after its session deactivates.
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    /// Refreshes companion app status when the paired Watch changes.
    nonisolated func sessionWatchStateDidChange(_: WCSession) {
        Task { @MainActor in self.updateWatchStatus() }
    }
}
