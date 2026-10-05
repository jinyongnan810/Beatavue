import Foundation
import HealthKit
import Observation

/// Records Watch workouts and mirrors their state to iPhone.
@MainActor @Observable
final class WatchWorkout: NSObject {
    /// Shared workout model used by the Watch interface and recovery delegate.
    static let shared = WatchWorkout()
    /// Current workout lifecycle state.
    private(set) var phase: WorkoutPhase = .idle
    /// Latest measured heart rate in beats per minute.
    private(set) var heartRate: Double?
    /// Timestamp of the latest heart-rate measurement.
    private(set) var measuredAt: Date?
    /// Active workout duration reported by HealthKit, excluding pauses.
    private(set) var elapsed: TimeInterval = 0
    /// Timestamp corresponding to the last elapsed-time update.
    private(set) var elapsedUpdatedAt = Date()
    /// Whether workout mirroring can send updates to iPhone.
    private(set) var phoneConnected = false
    /// Most recent workout or connection error shown to the user.
    private(set) var error: String?
    /// Whether HealthKit returned a saved workout.
    private(set) var saved = false
    /// Whether HealthKit data is available on this device.
    let available = HKHealthStore.isHealthDataAvailable()
    /// HealthKit store used to manage workout sessions and permissions.
    @ObservationIgnored private let store = HKHealthStore()
    /// HealthKit workout session managed by this model.
    @ObservationIgnored private var session: HKWorkoutSession?
    /// Live builder collecting and saving HealthKit measurements.
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    /// Identifier shared by updates from the same workout session.
    @ObservationIgnored private var sessionID = UUID()
    /// Task that sends workout updates to iPhone every five seconds.
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    /// Whether a mirroring connection request is already in progress.
    @ObservationIgnored private var mirroring = false
    /// Whether a workout update is already being sent.
    @ObservationIgnored private var sending = false

    /// Requests permissions and starts heart-rate collection for an Other workout.
    func start() async {
        guard available, session == nil, phase != .starting, phase != .saving else { return }
        phase = .starting
        error = nil
        saved = false
        heartRate = nil
        measuredAt = nil
        elapsed = 0
        phoneConnected = false
        sessionID = UUID()
        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [HKQuantityType(.heartRate)])
            guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                throw WorkoutError.workoutPermission
            }
            // Configuration for an Other workout with an unknown location.
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .other
            configuration.locationType = .unknown
            // HealthKit workout session managed by this model.
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            // Live builder collecting and saving HealthKit measurements.
            let builder = session.associatedWorkoutBuilder()
            // Live data source configured to collect heart rate only.
            let source = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            for type in source.typesToCollect where type != HKQuantityType(.heartRate) {
                source.disableCollection(for: type)
            }
            source.enableCollection(for: HKQuantityType(.heartRate), predicate: nil)
            builder.dataSource = source
            builder.delegate = self
            session.delegate = self
            self.session = session
            self.builder = builder
            // Shared start timestamp for the workout session and data collection.
            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            startHeartbeat()
            await reconnectPhone()
        } catch {
            session?.delegate = nil
            session?.end()
            builder?.discardWorkout()
            session = nil
            builder = nil
            phase = .failed
            self.error = error.localizedDescription
        }
    }

    /// Stops the active workout so its collected data can be saved.
    func stop() {
        guard phase == .running || phase == .paused else { return }
        phase = .saving
        session?.stopActivity(with: Date())
    }

    /// Pauses a running workout or resumes a paused workout.
    func togglePause() {
        if phase == .paused { session?.resume() }
        else if phase == .running { session?.pause() }
    }

    /// Starts mirroring to iPhone and sends the current workout state.
    func reconnectPhone() async {
        guard let session, !mirroring else { return }
        mirroring = true
        defer { mirroring = false }
        do {
            try await session.startMirroringToCompanionDevice()
            guard self.session === session else { return }
            phoneConnected = true
            error = nil
            await sendSnapshot()
        } catch {
            phoneConnected = false
            self.error = "Recording on Watch. \(error.localizedDescription)"
        }
    }

    /// Restarts the task that sends workout snapshots every five seconds.
    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendSnapshot()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    /// Sends the current workout state and elapsed time to the mirrored iPhone session.
    private func sendSnapshot() async {
        guard let session, let builder, phoneConnected, !sending else { return }
        sending = true
        defer { sending = false }
        elapsed = builder.elapsedTime
        elapsedUpdatedAt = Date()
        // Workout snapshot prepared for transmission to iPhone.
        let message = WorkoutSnapshot(sessionID: sessionID, state: phase, heartRate: heartRate,
                                      measuredAt: measuredAt, startedAt: session.startDate,
                                      elapsed: elapsed, sentAt: elapsedUpdatedAt)
        do {
            try await session.sendToRemoteWorkoutSession(data: JSONEncoder().encode(message))
        } catch {
            guard self.session === session else { return }
            phoneConnected = false
            self.error = "Recording on Watch. \(error.localizedDescription)"
        }
    }

    /// Ends collection, saves the workout, and releases the active session.
    private func finish(_ session: HKWorkoutSession, at date: Date) async {
        guard self.session === session, let builder else { return }
        phase = .saving
        await sendSnapshot()
        do {
            try await builder.endCollection(at: date)
            // Saved HealthKit workout, or nil if no workout was returned.
            let workout = try await builder.finishWorkout()
            saved = workout != nil
            if !saved { error = "Workout not saved." }
        } catch {
            saved = false
            self.error = "Could not save: \(error.localizedDescription)"
        }
        guard self.session === session else { return }
        elapsed = builder.elapsedTime
        elapsedUpdatedAt = date
        phase = .ended
        await sendSnapshot()
        session.end()
        heartbeat?.cancel()
        heartbeat = nil
        self.session = nil
        self.builder = nil
        phoneConnected = false
    }

    /// Restores an active HealthKit workout and resumes mirroring or finishes saving.
    func recover() async {
        guard session == nil else { return }
        do {
            guard let recovered = try await store.recoverActiveWorkoutSession() else { return }
            session = recovered
            builder = recovered.associatedWorkoutBuilder()
            recovered.delegate = self
            builder?.delegate = self
            phase = recovered.state == .paused ? .paused : .running
            elapsed = builder?.elapsedTime ?? 0
            elapsedUpdatedAt = Date()
            if recovered.state == .stopped {
                await finish(recovered, at: recovered.endDate ?? Date())
                return
            }
            startHeartbeat()
            await reconnectPhone()
        } catch {
            phase = .failed
            self.error = "Could not recover: \(error.localizedDescription)"
        }
    }
}

extension WatchWorkout: HKWorkoutSessionDelegate {
    /// Applies workout lifecycle changes on the main actor.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from _: HKWorkoutSessionState, date: Date)
    {
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.elapsed = self.builder?.elapsedTime ?? self.elapsed
            self.elapsedUpdatedAt = date
            switch toState {
            case .running: self.phase = .running
            case .paused: self.phase = .paused
            case .stopped: await self.finish(workoutSession, at: date); return
            case .ended:
                self.heartbeat?.cancel()
                self.session = nil
                self.builder = nil
                self.phase = .ended
            default: break
            }
            await self.sendSnapshot()
        }
    }

    /// Handles a workout session failure on the main actor.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.error = "Workout failed: \(error.localizedDescription)"
            self.phase = .failed
            await self.sendSnapshot()
            self.heartbeat?.cancel()
            self.builder?.discardWorkout()
            workoutSession.delegate = nil
            workoutSession.end()
            self.session = nil
            self.builder = nil
            self.phoneConnected = false
        }
    }

    /// Updates connection state when the remote workout device disconnects.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError _: Error?) {
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.phoneConnected = false
        }
    }
}

extension WatchWorkout: HKLiveWorkoutBuilderDelegate {
    /// Updates elapsed time when the live builder collects a workout event.
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        Task { @MainActor in
            guard self.builder === workoutBuilder else { return }
            self.elapsed = workoutBuilder.elapsedTime
            self.elapsedUpdatedAt = Date()
        }
    }

    /// Accepts the latest valid heart-rate measurement and sends it to iPhone.
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // Heart-rate quantity type used to inspect collected statistics.
        let type = HKQuantityType(.heartRate)
        guard collectedTypes.contains(type),
              // Collected heart-rate statistics from the live workout builder.
              let statistics = workoutBuilder.statistics(for: type),
              // Most recent heart-rate quantity in the collected statistics.
              let quantity = statistics.mostRecentQuantity(),
              // Time interval of the most recent heart-rate measurement.
              let interval = statistics.mostRecentQuantityDateInterval() else { return }
        // Latest collected heart rate converted to beats per minute.
        let value = quantity.doubleValue(for: .count().unitDivided(by: .minute()))
        // Timestamp of the latest heart-rate measurement.
        let measuredAt = interval.end
        Task { @MainActor in
            guard self.builder === workoutBuilder, self.phase == .running,
                  value.isFinite, value > 0, measuredAt >= (self.measuredAt ?? .distantPast) else { return }
            self.heartRate = value
            self.measuredAt = measuredAt
            self.elapsed = workoutBuilder.elapsedTime
            self.elapsedUpdatedAt = Date()
            await self.sendSnapshot()
        }
    }
}

/// Describes errors that prevent starting a Watch workout.
private enum WorkoutError: LocalizedError {
    case workoutPermission
    /// Explanation of the workout permission required to record.
    var errorDescription: String? {
        "Allow workout access in Health."
    }
}
