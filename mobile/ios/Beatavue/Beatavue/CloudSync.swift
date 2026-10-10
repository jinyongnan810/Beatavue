import Foundation
import HealthKit
import Observation
import Security
import UIKit

/// Portable server payload, independent of the local history cache format.
nonisolated struct CloudSample: Codable, Equatable, Sendable {
    let uuid: UUID
    let metric: String
    let value: Double
    let unit: String
    let start: String
    let end: String
    let source_name: String
    let source_identifier: String
    let source_version: String?
    let device_name: String?
    let device_model: String?

    init(_ sample: HealthSample) {
        uuid = sample.id
        metric = sample.metric == .heartRate ? "heart_rate" : "hrv_sdnn"
        value = sample.value
        unit = sample.metric.unit
        start = sample.start.ISO8601Format(.iso8601.year().month().day().dateSeparator(.dash).dateTimeSeparator(.standard).time(includingFractionalSeconds: true).timeZone(separator: .colon))
        end = sample.end.ISO8601Format(.iso8601.year().month().day().dateSeparator(.dash).dateTimeSeparator(.standard).time(includingFractionalSeconds: true).timeZone(separator: .colon))
        source_name = sample.sourceName
        source_identifier = sample.sourceIdentifier
        source_version = sample.sourceVersion
        device_name = sample.deviceName
        device_model = sample.deviceModel
    }
}

/// One stable addition or deletion; deletion wins for a UUID in each import.
nonisolated struct CloudOperation: Codable, Equatable, Sendable {
    let kind: String
    let uuid: UUID
    let sample: CloudSample?
}

/// An immutable batch survives termination and retains its ID for every retry.
nonisolated struct CloudBatch: Codable, Equatable, Sendable {
    let schema_version: Int
    let generation: UUID
    let batch_id: UUID
    let operations: [CloudOperation]
}

/// A fixed lower bound and its metric-specific HealthKit anchors.
nonisolated struct CloudWindow: Codable, Equatable, Sendable {
    let id: UUID
    let start: Date
    var anchors: [String: Data] = [:]
}

/// Queue changes and anchors are replaced together in one protected file.
nonisolated struct CloudState: Codable, Equatable, Sendable {
    var version = 1
    var endpoint = "https://beatavue.web.app"
    var enabled = false
    var generation: UUID?
    var importID: UUID?
    var deletionID: UUID?
    var windows: [CloudWindow] = []
    var batches: [CloudBatch] = []
    var lastUpload: Date?
    var retryAt: Date?
    var failures = 0

    /// The original formatter emitted only a time. The API rejected those batches atomically,
    /// so reread their additions from HealthKit instead of inventing the missing dates.
    mutating func recoverTimeOnlyBatches() -> Bool {
        func missingDate(_ operation: CloudOperation) -> Bool {
            guard let sample = operation.sample else { return false }
            return !sample.start.contains("T") || !sample.end.contains("T")
        }
        guard batches.contains(where: { $0.operations.contains(where: missingDate) }) else { return false }
        batches = batches.compactMap { batch in
            guard batch.operations.contains(where: missingDate) else { return batch }
            // Retain queued deletions and any correctly encoded additions. A changed payload
            // gets a fresh batch ID; already valid batches keep their original retry identity.
            let retained = batch.operations.filter { !missingDate($0) }
            guard !retained.isEmpty else { return nil }
            return CloudBatch(schema_version: batch.schema_version, generation: batch.generation,
                              batch_id: UUID(), operations: retained)
        }
        for index in windows.indices {
            windows[index].anchors = [:]
        }
        failures = 0
        retryAt = nil
        return true
    }
}

/// The token is device-local and is never written with health data or settings.
nonisolated enum CloudToken {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.kinn.Beatavue.cloud",
         kSecAttrAccount as String: "upload-token"]
    }

    static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { throw CloudFailure.message("Upload token unavailable. Unlock your iPhone and configure the token.") }
        return token
    }

    static func write(_ token: String) throws {
        guard token.count >= 32 else { throw CloudFailure.message("Use a token with at least 32 characters.") }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
            else { throw CloudFailure.message("Could not store the upload token in Keychain.") }
        } else if status != errSecSuccess {
            throw CloudFailure.message("Could not update the upload token in Keychain.")
        }
    }
}

nonisolated enum CloudFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case let .message(text): text }
    }
}

/// URLSession delegates are called off the UI actor; buffers are lock-protected.
final nonisolated class CloudTransfers: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let identifier = "com.kinn.Beatavue.health-upload"
    private let lock = NSLock()
    private var buffers: [Int: Data] = [:]
    var result: (@MainActor @Sendable (String, Int, Data, Bool) -> Void)?
    var eventsFinished: (@MainActor @Sendable () -> Void)?
    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if (buffers[dataTask.taskIdentifier]?.count ?? 0) + data.count <= 65536 {
            buffers[dataTask.taskIdentifier, default: Data()].append(data)
        }
        lock.unlock()
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let data = buffers.removeValue(forKey: task.taskIdentifier) ?? Data()
        lock.unlock()
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let description = task.taskDescription ?? ""
        let failed = error != nil
        Task { @MainActor in self.result?(description, status, data, failed) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        Task { @MainActor in self.eventsFinished?() }
    }

    // Do not follow redirects carrying the private token to another endpoint.
    func urlSession(_: URLSession, task _: URLSessionTask,
                    willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}

/// Owns opt-in, anchored reads, durable queueing, and upload acknowledgments.
@MainActor @Observable
final class CloudSync {
    static let shared = CloudSync()
    private(set) var state = CloudState()
    private(set) var error: String?
    private(set) var working = false
    private(set) var ready = false
    @ObservationIgnored private let health = HKHealthStore()
    @ObservationIgnored private let transfers = CloudTransfers()
    @ObservationIgnored private var observers: [HKObserverQuery] = []
    @ObservationIgnored private var catchup: Task<Void, Never>?
    @ObservationIgnored private var catchupID: UUID?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var activeTransfer: String?
    @ObservationIgnored private var restoringTransfers = true
    @ObservationIgnored private var backgroundCompletion: (() -> Void)?

    var pendingCount: Int { state.batches.reduce(0) { $0 + $1.operations.count } }

    /// Initializes once during application launch, including background relaunches.
    func start() {
        guard !ready else { return }
        transfers.result = { [weak self] identity, status, data, failed in
            self?.received(identity: identity, status: status, data: data, failed: failed)
        }
        transfers.eventsFinished = { [weak self] in
            self?.backgroundCompletion?()
            self?.backgroundCompletion = nil
        }
        do {
            let url = try directory().appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: url.path) {
                state = try JSONDecoder().decode(CloudState.self, from: Data(contentsOf: url))
                guard state.version == 1 else { throw CloudFailure.message("Unsupported cloud sync state.") }
                var recovered = state
                if recovered.recoverTimeOnlyBatches() { try save(recovered) }
            }
            if state.enabled {
                // Upgrade upload copies from the previous release before reattaching tasks.
                for batch in state.batches {
                    let file = try directory().appendingPathComponent("upload-\(batch.batch_id.uuidString).json")
                    if FileManager.default.fileExists(atPath: file.path) {
                        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                              ofItemAtPath: file.path)
                    }
                }
            }
            ready = true
            registerObservers()
            Task {
                let tasks = await transfers.session.allTasks
                // Adopt an existing transfer before scheduling another after relaunch.
                if let batch = state.batches.first, state.enabled,
                   let task = tasks.first(where: { $0.taskDescription?.hasPrefix(batch.batch_id.uuidString) == true })
                {
                    activeTransfer = task.taskDescription
                    for other in tasks where other !== task {
                        other.cancel()
                    }
                } else {
                    for task in tasks {
                        task.cancel()
                    }
                }
                restoringTransfers = false
                await syncNow()
                scheduleUpload()
            }
        } catch {
            self.error = "Could not load cloud sync state. Unlock your iPhone and retry."
        }
    }

    func handleBackgroundEvents(_ completion: @escaping () -> Void) {
        backgroundCompletion = completion
        start()
        _ = transfers.session
    }

    private func directory() throws -> URL {
        let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true).appendingPathComponent("BeatavueCloud", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return url
    }

    /// Synchronous replacement prevents actor reentrancy from splitting anchors and changes.
    private func save(_ next: CloudState) throws {
        let data = try JSONEncoder().encode(next)
        try data.write(to: directory().appendingPathComponent("state.json"), options: [.atomic, .completeFileProtection])
        state = next
    }

    func configure(endpoint: String, token: String) async {
        do {
            guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/"
            else { throw CloudFailure.message("Use an HTTPS base URL without a path, query, or credentials.") }
            let normalized = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
            if normalized != state.endpoint {
                guard !working else { throw CloudFailure.message("Wait for the current sync action to finish.") }
                // Changing endpoints always disables publishing and resets the local import.
                try save(CloudState(endpoint: normalized))
                cancelWork()
            }
            if !token.isEmpty { try CloudToken.write(token) }
            error = nil
            await syncNow()
        } catch { self.error = error.localizedDescription }
    }

    /// Called only after an explicit public-publishing confirmation in Settings.
    func enable() async {
        guard ready, !working else { return }
        working = true
        defer { working = false }
        do {
            if state.deletionID != nil { throw CloudFailure.message("Finish the pending cloud deletion before importing again.") }
            if state.generation == nil {
                var next = state
                if next.importID == nil { next.importID = UUID() }
                try save(next)
                let response = try await control("/v1/import", method: "POST", fields: ["import_id": next.importID!.uuidString])
                guard let raw = response["generation"] as? String, let generation = UUID(uuidString: raw)
                else { throw CloudFailure.message("Invalid import acknowledgment.") }
                next.generation = generation
                next.windows = [CloudWindow(id: UUID(), start: Calendar.autoupdatingCurrent.date(byAdding: .day, value: -29,
                                                                                                 to: Calendar.autoupdatingCurrent.startOfDay(for: Date()))!)]
                next.enabled = true
                try save(next)
            } else {
                var next = state
                next.enabled = true
                try save(next)
            }
            registerObservers()
            error = nil
        } catch { self.error = error.localizedDescription }
        // Defer releases working after returning; schedule separately.
        Task { await self.syncNow() }
    }

    /// Pauses publishing but retains the queue and anchors for a later resume.
    func disable() {
        do {
            var next = state
            next.enabled = false
            try save(next)
            cancelWork()
            error = nil
        } catch { self.error = "Could not pause sync. Unlock your iPhone and retry." }
    }

    private func cancelWork() {
        catchup?.cancel()
        catchup = nil
        catchupID = nil
        retryTask?.cancel()
        activeTransfer = nil
        restoringTransfers = true
        Task {
            for task in await transfers.session.allTasks {
                task.cancel()
            }
            if let directory = try? directory(), let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix("upload-") {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            restoringTransfers = false
            scheduleUpload()
        }
        for observer in observers {
            health.stop(observer)
        }
        observers = []
        // Stopping observers prevents uploads; no global disable can race a later opt-in.
    }

    /// Recovery when the server dataset was replaced outside this device.
    func resetLocalSync() {
        guard !working, state.deletionID == nil else { return }
        do {
            try save(CloudState(endpoint: state.endpoint))
            cancelWork()
            error = nil
        } catch { self.error = "Could not reset sync. Unlock your iPhone and retry." }
    }

    /// Disables locally before making the generation-fenced server deletion request.
    func deleteCloudData() async {
        guard ready, !working else { return }
        working = true
        defer { working = false }
        do {
            guard let generation = state.generation else { return }
            var next = state
            next.enabled = false
            next.batches = []
            next.windows = []
            if next.deletionID == nil { next.deletionID = UUID() }
            try save(next)
            cancelWork()
            let result = try await control("/v1/data", method: "DELETE", fields: [
                "generation": generation.uuidString, "deletion_id": next.deletionID!.uuidString,
            ])
            if result["cleanup_pending"] as? Bool == false {
                next.generation = nil
                next.importID = nil
                next.deletionID = nil
                next.lastUpload = nil
                try save(next)
                error = nil
            } else {
                error = "Cloud data is hidden. Deletion is finishing; tap Delete cloud history again to check completion."
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Expanding the publication range requires a separate owner action.
    func importHistory(from date: Date) async {
        guard state.enabled, ready, !working else { return }
        do {
            if let earliest = state.windows.map(\.start).min(), date < earliest {
                var next = state
                // A new fixed predicate gets its own anchors; overlapping UUIDs remain idempotent.
                next.windows.append(CloudWindow(id: UUID(), start: date))
                try save(next)
            }
            await syncNow()
        } catch { self.error = error.localizedDescription }
    }

    private func registerObservers() {
        guard state.enabled, observers.isEmpty, HKHealthStore.isHealthDataAvailable() else { return }
        for metric in HealthMetric.allCases {
            let observer = HKObserverQuery(sampleType: metric.quantityType, predicate: nil) { [weak self] _, completion, error in
                Task { @MainActor in
                    guard let self else { completion(); return }
                    if error == nil { await self.syncNow() }
                    // syncNow persists additions/deletions and anchors before completion, never waits for HTTP.
                    completion()
                }
            }
            observers.append(observer)
            health.execute(observer)
            Task {
                do { try await health.enableBackgroundDelivery(for: metric.quantityType, frequency: .immediate) }
                catch { self.error = "Background Health delivery unavailable. Open the app to catch up." }
            }
        }
    }

    func syncNow() async {
        guard ready, state.enabled else { return }
        if let catchup { await catchup.value; return }
        let id = UUID()
        let task = Task { await self.collect() }
        catchupID = id
        catchup = task
        await task.value
        if catchupID == id { catchup = nil; catchupID = nil }
        scheduleUpload()
    }

    private func collect() async {
        guard let generation = state.generation, HKHealthStore.isHealthDataAvailable() else { return }
        do {
            let windows = state.windows
            for window in windows {
                for metric in HealthMetric.allCases {
                    var more = true
                    while more {
                        try Task.checkCancellation()
                        guard state.enabled, state.generation == generation,
                              let index = state.windows.firstIndex(where: { $0.id == window.id }) else { return }
                        let encodedAnchor = state.windows[index].anchors[metric.rawValue]
                        let anchor = try encodedAnchor.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
                        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: nil, options: .strictStartDate)
                        let query = HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: metric.quantityType, predicate: predicate)],
                                                                    anchor: anchor, limit: 100)
                        let result = try await query.result(for: health)
                        try Task.checkCancellation()
                        guard state.enabled, state.generation == generation else { return }
                        var operations: [UUID: CloudOperation] = [:]
                        for sample in result.addedSamples {
                            operations[sample.uuid] = CloudOperation(kind: "upsert", uuid: sample.uuid,
                                                                     sample: CloudSample(HealthSample(sample, metric: metric)))
                        }
                        for deleted in result.deletedObjects {
                            operations[deleted.uuid] = CloudOperation(kind: "delete", uuid: deleted.uuid, sample: nil)
                        }
                        var next = state
                        let ordered = operations.values.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
                        for offset in stride(from: 0, to: ordered.count, by: 100) {
                            next.batches.append(CloudBatch(schema_version: 1, generation: generation, batch_id: UUID(),
                                                           operations: Array(ordered[offset ..< min(offset + 100, ordered.count)])))
                        }
                        next.windows[index].anchors[metric.rawValue] = try NSKeyedArchiver.archivedData(withRootObject: result.newAnchor,
                                                                                                        requiringSecureCoding: true)
                        try save(next)
                        more = !result.addedSamples.isEmpty || !result.deletedObjects.isEmpty
                    }
                }
            }
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = "Could not queue Health changes. Unlock your iPhone and tap Sync now."
        }
    }

    private func scheduleUpload() {
        guard state.enabled, !restoringTransfers, activeTransfer == nil, let batch = state.batches.first else { return }
        do {
            let token = try CloudToken.read()
            let file = try directory().appendingPathComponent("upload-\(batch.batch_id.uuidString).json")
            let data = try JSONEncoder().encode(batch)
            guard data.count <= 256 * 1024 else { throw CloudFailure.message("Upload batch exceeds the server limit.") }
            // The background transfer daemon must reopen this file while the device is locked.
            // Keep the durable queue at complete protection; relax only its temporary upload copy.
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var request = URLRequest(url: URL(string: state.endpoint + "/v1/sync")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let task = transfers.session.uploadTask(with: request, fromFile: file)
            let identity = batch.batch_id.uuidString + ":" + UUID().uuidString
            task.taskDescription = identity
            task.earliestBeginDate = state.retryAt
            activeTransfer = identity
            task.resume()
        } catch { self.error = error.localizedDescription }
    }

    /// Only a matching durable acknowledgment removes a queued batch.
    private func received(identity: String, status: Int, data: Data, failed: Bool) {
        guard activeTransfer == identity else { return }
        activeTransfer = nil
        guard state.enabled, let batch = state.batches.first,
              identity.hasPrefix(batch.batch_id.uuidString) else { return }
        do {
            var next = state
            let ack = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if !failed, status == 200,
               (ack?["batch_id"] as? String)?.lowercased() == batch.batch_id.uuidString.lowercased(),
               (ack?["generation"] as? String)?.lowercased() == batch.generation.uuidString.lowercased(),
               ack?["acknowledged"] as? Int == batch.operations.count
            {
                next.batches.removeFirst()
                next.lastUpload = Date()
                next.failures = 0
                next.retryAt = nil
                try save(next)
                try? FileManager.default.removeItem(at: directory().appendingPathComponent("upload-\(batch.batch_id.uuidString).json"))
                error = nil
                scheduleUpload()
            } else {
                next.failures = min(next.failures + 1, 12)
                let delay = min(pow(2, Double(next.failures)) * 5, 3600) + Double.random(in: 0 ... 10)
                next.retryAt = Date().addingTimeInterval(delay)
                try save(next)
                if status == 401 || status == 409 || status == 400 || status == 413 {
                    error = "Upload rejected (\(status)). Check the token and server import. Pending changes are retained."
                } else {
                    error = "Upload delayed. Pending changes are saved and will retry."
                    retryTask = Task {
                        try? await Task.sleep(for: .seconds(delay))
                        guard !Task.isCancelled else { return }
                        self.scheduleUpload()
                    }
                    // The system schedules this file upload even if the app is suspended.
                    scheduleUpload()
                }
            }
        } catch { self.error = "Could not save the upload acknowledgment. The same batch will retry safely." }
    }

    private func control(_ path: String, method: String, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: state.endpoint + path)!)
        request.httpMethod = method
        request.timeoutInterval = 55
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try request.setValue("Bearer " + (CloudToken.read()), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let session = URLSession(configuration: .ephemeral, delegate: transfers, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw CloudFailure.message("Cloud action failed. Check connectivity, token, and whether deletion is still finishing.")
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudFailure.message("Invalid server response.")
        }
        return result
    }
}

/// Reconnects background file transfers before the system delivers their events.
final class CloudAppDelegate: NSObject, UIApplicationDelegate {
    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CloudSync.shared.start()
        return true
    }

    func application(_: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void)
    {
        guard identifier == CloudTransfers.identifier else { completionHandler(); return }
        CloudSync.shared.handleBackgroundEvents(completionHandler)
    }
}
