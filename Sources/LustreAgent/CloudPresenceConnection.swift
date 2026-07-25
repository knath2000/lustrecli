import Foundation
import LustreCore

public actor CloudPresenceConnection {
    public static let heartbeatInterval: TimeInterval = 30
    private let identity: DeviceIdentity
    private let session: URLSession
    private var runner: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    public init(identity: DeviceIdentity = DeviceIdentity(), session: URLSession = .shared) { self.identity = identity; self.session = session }

    public func startIfEnrolled() {
        guard runner == nil, let enrollment = try? DeviceEnrollmentStore.load() else { return }
        runner = Task { await run(enrollment) }
    }

    public func stop() { runner?.cancel(); runner = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil }

    private func run(_ enrollment: CloudEnrollmentMetadata) async {
        var delay: TimeInterval = 1
        while !Task.isCancelled {
            do {
                let client = try CloudEnrollmentClient(origin: URL(string: enrollment.cloudOrigin)!)
                let challenge = try await client.deviceSessionChallenge(deviceID: enrollment.deviceID)
                let envelope = try CloudDeviceProtocol.envelope(purpose: "session", audience: enrollment.cloudOrigin, subjectID: enrollment.deviceID.uuidString.lowercased(), nonce: challenge.nonce, thumbprint: try identity.thumbprint(), expiresAt: challenge.expiresAt)
                let completed = try await client.completeDeviceSession(deviceID: enrollment.deviceID, challengeID: challenge.challengeID, signature: try identity.sign(envelope))
                try await connect(origin: enrollment.cloudOrigin, token: completed.accessToken)
                delay = 1
            } catch CloudDeviceError.deviceRevoked { return }
            catch {
                let nanoseconds = UInt64((delay + Double.random(in: 0...min(delay * 0.2, 3))) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                delay = min(delay * 2, 60)
            }
        }
    }

    private func connect(origin: String, token: String) async throws {
        guard var components = URLComponents(string: origin) else { throw CloudDeviceError.invalidOrigin }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/cloud/v1/realtime"
        components.query = nil
        guard let url = components.url else { throw CloudDeviceError.invalidOrigin }
        let task = session.webSocketTask(with: url, protocols: ["lustre-v1", "lustre.\(token)"])
        socket = task; task.resume()
        var sequence = 1
        while !Task.isCancelled {
            let frame: [String: Any] = ["version": 1, "type": "heartbeat", "sequence": sequence, "sentAt": ISO8601DateFormatter().string(from: .now), "agentVersion": "0.1.0"]
            let data = try JSONSerialization.data(withJSONObject: frame)
            try await task.send(.data(data))
            let response = try await task.receive()
            let responseData: Data
            switch response { case let .data(data): responseData = data; case let .string(text): responseData = Data(text.utf8); @unknown default: throw CloudDeviceError.invalidResponse }
            guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any], object["version"] as? Int == 1, object["type"] as? String == "heartbeat-accepted", object["sequence"] as? Int == sequence else { throw CloudDeviceError.invalidResponse }
            sequence += 1
            try await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
        }
    }
}
