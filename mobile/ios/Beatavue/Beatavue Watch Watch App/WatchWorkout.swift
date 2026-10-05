import Foundation
import HealthKit
import Observation

@MainActor @Observable
final class WatchWorkout: NSObject {
    static let shared = WatchWorkout()
    private(set) var phase: WorkoutPhase = .idle
    private(set) var heartRate: Double?
    private(set) var measuredAt: Date?
    private(set) var elapsed: TimeInterval = 0
    private(set) var elapsedUpdatedAt = Date()
    private(set) var phoneConnected = false
    private(set) var error: String?
    private(set) var saved = false
    let available = HKHealthStore.isHealthDataAvailable()
    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var mirroring = false
    @ObservationIgnored private var sending = false

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
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .other
            configuration.locationType = .unknown
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
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

    func stop() {
        guard phase == .running || phase == .paused else { return }
        phase = .saving
        session?.stopActivity(with: Date())
    }

    func togglePause() {
        if phase == .paused { session?.resume() }
        else if phase == .running { session?.pause() }
    }

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
            self.error = "iPhone disconnected: \(error.localizedDescription). Recording continues on Apple Watch."
        }
    }

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

    private func sendSnapshot() async {
        guard let session, let builder, phoneConnected, !sending else { return }
        sending = true
        defer { sending = false }
        elapsed = builder.elapsedTime
        elapsedUpdatedAt = Date()
        let message = WorkoutSnapshot(sessionID: sessionID, state: phase, heartRate: heartRate,
                                      measuredAt: measuredAt, startedAt: session.startDate,
                                      elapsed: elapsed, sentAt: elapsedUpdatedAt)
        do {
            try await session.sendToRemoteWorkoutSession(data: JSONEncoder().encode(message))
        } catch {
            guard self.session === session else { return }
            phoneConnected = false
            self.error = "iPhone disconnected: \(error.localizedDescription). Recording continues on Apple Watch."
        }
    }

    private func finish(_ session: HKWorkoutSession, at date: Date) async {
        guard self.session === session, let builder else { return }
        phase = .saving
        await sendSnapshot()
        do {
            try await builder.endCollection(at: date)
            let workout = try await builder.finishWorkout()
            saved = workout != nil
            if !saved { error = "The workout ended, but Apple Health did not return a saved workout." }
        } catch {
            saved = false
            self.error = "The workout could not be saved: \(error.localizedDescription)"
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
            self.error = "Could not recover the workout: \(error.localizedDescription)"
        }
    }
}

extension WatchWorkout: HKWorkoutSessionDelegate {
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

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError _: Error?) {
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.phoneConnected = false
        }
    }
}

extension WatchWorkout: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        Task { @MainActor in
            guard self.builder === workoutBuilder else { return }
            self.elapsed = workoutBuilder.elapsedTime
            self.elapsedUpdatedAt = Date()
        }
    }

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let type = HKQuantityType(.heartRate)
        guard collectedTypes.contains(type),
              let statistics = workoutBuilder.statistics(for: type),
              let quantity = statistics.mostRecentQuantity(),
              let interval = statistics.mostRecentQuantityDateInterval() else { return }
        let value = quantity.doubleValue(for: .count().unitDivided(by: .minute()))
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

private enum WorkoutError: LocalizedError {
    case workoutPermission
    var errorDescription: String? {
        "Allow Beatavue to save workouts in Health permissions to start a recording."
    }
}
