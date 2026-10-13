import Foundation
import Observation
import Security
import WatchConnectivity

nonisolated struct LiveConfiguration: Codable, Sendable {
    let endpoint: String
    let token: String?
    let generation: UUID?
    let enabled: Bool
    let revisedAt: Date
}

nonisolated struct LivePayload: Encodable, Sendable {
    let generation: UUID
    let session_id: UUID
    let started_at: String
    let sent_at: String
    let updating: Bool
    let heart_rate: Double?
    let measured_at: String?
}

/// Live uploads are best effort: one request in flight, one latest state, no historical queue.
@MainActor @Observable
final class LiveUpload: NSObject, WCSessionDelegate {
    static let shared = LiveUpload()
    private(set) var enabled = false
    private(set) var error: LocalizedStringResource?
    @ObservationIgnored private var configuration: LiveConfiguration?
    @ObservationIgnored private var pending: LivePayload?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private let transport = LiveTransport()
    @ObservationIgnored private lazy var http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config, delegate: transport, delegateQueue: nil)
    }()

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.kinn.Beatavue.live",
         kSecAttrAccount as String: "connection"]
    }

    func start() {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let saved = try? JSONDecoder().decode(LiveConfiguration.self, from: data)
        {
            configuration = saved
            enabled = saved.enabled && saved.token != nil && saved.generation != nil
        }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func requestConfiguration() {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["requestLiveConfiguration": true], replyHandler: nil, errorHandler: nil)
    }

    private func receive(_ data: Data) {
        guard let next = try? JSONDecoder().decode(LiveConfiguration.self, from: data),
              next.revisedAt >= (configuration?.revisedAt ?? .distantPast),
              let url = URL(string: next.endpoint), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return }
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
        let stored = status == errSecSuccess || (status == errSecItemNotFound &&
            SecItemAdd(keychainQuery.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess)
        guard stored else { error = "Could not save live publishing credentials."; return }
        let changed = configuration?.endpoint != next.endpoint || configuration?.generation != next.generation || configuration?.token != next.token
        configuration = next
        enabled = next.enabled && (next.token?.count ?? 0) >= 32 && next.generation != nil
        if !enabled || changed {
            pending = nil
            worker?.cancel()
            worker = nil
            retry?.cancel()
            retry = nil
        }
        error = nil
    }

    func update(sessionID: UUID, startedAt: Date, heartRate: Double?, measuredAt: Date?, running: Bool) {
        guard enabled, let generation = configuration?.generation else { return }
        let now = Date()
        let active = running && heartRate != nil && measuredAt.map { now.timeIntervalSince($0) <= 30 } == true
        func stamp(_ date: Date) -> String {
            date.ISO8601Format(.iso8601.year().month().day().dateSeparator(.dash).dateTimeSeparator(.standard).time(includingFractionalSeconds: true).timeZone(separator: .colon))
        }
        pending = LivePayload(generation: generation, session_id: sessionID, started_at: stamp(startedAt),
                              sent_at: stamp(now), updating: active, heart_rate: active ? heartRate : nil,
                              measured_at: active ? measuredAt.map(stamp) : nil)
        retry?.cancel()
        retry = nil
        drain()
    }

    private func drain() {
        guard worker == nil, pending != nil, enabled else { return }
        worker = Task {
            while !Task.isCancelled, enabled, let payload = pending,
                  let connection = configuration, let token = connection.token
            {
                pending = nil
                do {
                    var request = URLRequest(url: URL(string: connection.endpoint + "/v1/live")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                    request.httpBody = try JSONEncoder().encode(payload)
                    let (_, response) = try await http.data(for: request)
                    guard !Task.isCancelled else { return }
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                        requestConfiguration()
                        throw URLError(.badServerResponse)
                    }
                    error = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = "Live publishing delayed. Recording continues on Watch."
                    // Keep just the newest state. Retry briefly, then discard expired live data.
                    if pending == nil { pending = payload }
                    worker = nil
                    retry = Task {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        if let pending, let sent = formatter.date(from: pending.sent_at),
                           Date().timeIntervalSince(sent) > 30 { self.pending = nil }
                        self.drain()
                    }
                    return
                }
            }
            worker = nil
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith _: WCSessionActivationState, error _: Error?) {
        let data = session.receivedApplicationContext["liveConfiguration"] as? Data
        Task { @MainActor in
            if let data { self.receive(data) }
            self.requestConfiguration()
        }
    }

    nonisolated func session(_: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["liveConfiguration"] as? Data else { return }
        Task { @MainActor in self.receive(data) }
    }

    nonisolated func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message["liveConfiguration"] as? Data else { return }
        Task { @MainActor in self.receive(data) }
    }
}

/// Never follow a redirect carrying the owner token.
final nonisolated class LiveTransport: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}
