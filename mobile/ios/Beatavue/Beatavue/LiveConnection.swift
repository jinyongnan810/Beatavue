import Foundation
import WatchConnectivity

/// Configuration is encoded for transport only; the upload token stays in Keychain on each device.
nonisolated struct LiveConfiguration: Codable, Sendable {
    let endpoint: String
    let token: String?
    let generation: UUID?
    let enabled: Bool
    let revisedAt: Date
}

/// Sends the latest public-publishing permission and credentials to the paired Watch.
@MainActor
final class LiveConnection: NSObject, WCSessionDelegate {
    static let shared = LiveConnection()
    private var lastConfiguration: LiveConfiguration?

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func synchronize(force: Bool = false) {
        guard CloudSync.shared.ready, WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let state = CloudSync.shared.state
        let enabled = state.enabled && state.liveEnabled == true
        let configuration = LiveConfiguration(endpoint: state.endpoint,
                                              token: enabled ? try? CloudToken.read() : nil,
                                              generation: state.generation, enabled: enabled, revisedAt: Date())
        guard !enabled || configuration.token != nil else { return }
        if !force, let lastConfiguration,
           lastConfiguration.endpoint == configuration.endpoint,
           lastConfiguration.token == configuration.token,
           lastConfiguration.generation == configuration.generation,
           lastConfiguration.enabled == configuration.enabled { return }
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        // Context replaces unsent old configuration and is delivered after reconnection.
        do {
            try WCSession.default.updateApplicationContext(["liveConfiguration": data])
            lastConfiguration = configuration
        } catch { return }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["liveConfiguration": data], replyHandler: nil, errorHandler: nil)
        }
    }

    nonisolated func session(_: WCSession, activationDidCompleteWith _: WCSessionActivationState, error _: Error?) {
        Task { @MainActor in self.synchronize(force: true) }
    }

    nonisolated func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["requestLiveConfiguration"] as? Bool == true else { return }
        Task { @MainActor in self.synchronize(force: true) }
    }

    nonisolated func sessionDidBecomeInactive(_: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
