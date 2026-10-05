import Foundation
import HealthKit
import Observation
import WatchConnectivity

@MainActor @Observable
final class PhoneWorkout: NSObject {
    private(set) var snapshot: WorkoutSnapshot?
    private(set) var disconnected = false
    private(set) var watchStatus: LocalizedStringResource = "Checking Apple Watch"
    private(set) var error: String?
    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var connectivity: WCSession?

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

    private func attach(_ session: HKWorkoutSession) {
        self.session?.delegate = nil
        self.session = session
        session.delegate = self
        let phase: WorkoutPhase = session.state == .paused ? .paused : .running
        snapshot = WorkoutSnapshot(sessionID: UUID(), state: phase, heartRate: nil,
                                   measuredAt: nil, startedAt: session.startDate, elapsed: 0, sentAt: Date())
        disconnected = false
        error = nil
    }

    private func receive(_ messages: [Data], from session: HKWorkoutSession) {
        guard self.session === session else { return }
        for data in messages {
            do {
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

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.error = error.localizedDescription
            self.disconnected = true
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        Task { @MainActor in self.receive(data, from: workoutSession) }
    }

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
    nonisolated func session(_: WCSession, activationDidCompleteWith _: WCSessionActivationState, error _: Error?) {
        Task { @MainActor in self.updateWatchStatus() }
    }

    nonisolated func sessionDidBecomeInactive(_: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_: WCSession) {
        Task { @MainActor in self.updateWatchStatus() }
    }
}
