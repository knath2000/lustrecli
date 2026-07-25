import Foundation

enum CloudPresenceReconnectReason: String {
    case transportClosed = "transport_closed"
    case sessionAuthenticationFailed = "session_authentication_failed"
    case serverRequestedReconnect = "server_requested_reconnect"

    func logMessage(generation: CloudPresenceReconnectStateMachine.Generation, retryDelay: TimeInterval) -> String {
        "Lustre Cloud presence reconnecting: reason=\(rawValue) generation=\(generation) retryDelaySeconds=\(String(format: "%.3f", retryDelay))."
    }
}

struct CloudPresenceReconnectStateMachine {
    typealias Generation = UInt64

    static let initialBackoff: TimeInterval = 1
    static let maximumBackoff: TimeInterval = 60

    private(set) var activeGeneration: Generation?
    private(set) var isRevoked = false
    private var nextGeneration: Generation = 0
    private var nextBackoff = Self.initialBackoff
    private let jitter: (TimeInterval) -> TimeInterval

    init(jitter: @escaping (TimeInterval) -> TimeInterval = { delay in
        Double.random(in: 0...min(delay * 0.2, 3))
    }) {
        self.jitter = jitter
    }

    mutating func beginConnection() -> Generation? {
        guard !isRevoked, activeGeneration == nil else { return nil }
        nextGeneration &+= 1
        activeGeneration = nextGeneration
        return nextGeneration
    }

    func requiresFreshSessionToken(for generation: Generation) -> Bool {
        activeGeneration == generation && !isRevoked
    }

    func maySendHeartbeat(for generation: Generation) -> Bool {
        activeGeneration == generation && !isRevoked
    }

    mutating func connectionFailed(_ generation: Generation) -> TimeInterval? {
        guard activeGeneration == generation, !isRevoked else { return nil }
        activeGeneration = nil
        let delay = nextBackoff + min(max(jitter(nextBackoff), 0), min(nextBackoff * 0.2, 3))
        nextBackoff = min(nextBackoff * 2, Self.maximumBackoff)
        return delay
    }

    mutating func stopForRevocation() {
        isRevoked = true
        activeGeneration = nil
    }

    mutating func stop() {
        activeGeneration = nil
    }
}
