import Foundation
import LustreCore

private enum CloudPresenceConnectionError: Error {
    case serverRequestedReconnect
}

public actor CloudPresenceConnection {
    public static let heartbeatInterval: TimeInterval = 30
    private let identity: DeviceIdentity
    private let session: URLSession
    private let remoteControl: CloudRemoteControl
    private var runner: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var reconnectState = CloudPresenceReconnectStateMachine()

    public init(service: AgentService, identity: DeviceIdentity = DeviceIdentity(), session: URLSession = .shared) { self.identity = identity; self.session = session; remoteControl = CloudRemoteControl(service: service) }

    public func startIfEnrolled() {
        guard runner == nil, let enrollment = try? DeviceEnrollmentStore.load() else { return }
        runner = Task { await run(enrollment) }
    }

    public func stop() { runner?.cancel(); runner = nil; reconnectState.stop(); socket?.cancel(with: .goingAway, reason: nil); socket = nil }

    private func run(_ enrollment: CloudEnrollmentMetadata) async {
        while !Task.isCancelled {
            guard let generation = reconnectState.beginConnection() else { return }
            var reconnectReason = CloudPresenceReconnectReason.sessionAuthenticationFailed
            do {
                guard reconnectState.requiresFreshSessionToken(for: generation) else { return }
                let client = try CloudEnrollmentClient(origin: URL(string: enrollment.cloudOrigin)!)
                let challenge = try await client.deviceSessionChallenge(deviceID: enrollment.deviceID)
                let envelope = try CloudDeviceProtocol.envelope(purpose: "session", audience: enrollment.cloudOrigin, subjectID: enrollment.deviceID.uuidString.lowercased(), nonce: challenge.nonce, thumbprint: try identity.thumbprint(), expiresAt: challenge.expiresAt)
                let completed = try await client.completeDeviceSession(deviceID: enrollment.deviceID, challengeID: challenge.challengeID, signature: try identity.sign(envelope))
                reconnectReason = .transportClosed
                try await connect(origin: enrollment.cloudOrigin, token: completed.accessToken, generation: generation)
            } catch CloudPresenceConnectionError.serverRequestedReconnect {
                guard let delay = reconnectState.connectionFailed(generation) else { return }
                fputs(CloudPresenceReconnectReason.serverRequestedReconnect.logMessage(generation: generation, retryDelay: delay) + "\n", stderr)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch CloudDeviceError.deviceRevoked {
                reconnectState.stopForRevocation()
                fputs("Lustre Cloud presence stopped: reason=device_revoked generation=\(generation).\n", stderr)
                return
            }
            catch CloudDeviceError.keychainFailure {
                reconnectState.stop()
                fputs("Lustre Cloud presence stopped: Keychain access requires user authorization.\n", stderr)
                return
            }
            catch {
                guard let delay = reconnectState.connectionFailed(generation) else { return }
                fputs(reconnectReason.logMessage(generation: generation, retryDelay: delay) + "\n", stderr)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func connect(origin: String, token: String, generation: CloudPresenceReconnectStateMachine.Generation) async throws {
        guard reconnectState.requiresFreshSessionToken(for: generation) else { return }
        guard var components = URLComponents(string: origin) else { throw CloudDeviceError.invalidOrigin }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/cloud/v1/realtime"
        components.query = nil
        guard let url = components.url else { throw CloudDeviceError.invalidOrigin }
        let task = session.webSocketTask(with: url, protocols: ["lustre-v1", "lustre.\(token)"])
        fputs("Lustre Cloud presence connecting: generation=\(generation).\n", stderr)
        socket = task; task.resume()
        var sequence = 1
        while !Task.isCancelled {
            guard reconnectState.maySendHeartbeat(for: generation) else {
                task.cancel(with: .goingAway, reason: nil)
                return
            }
            let payload = await remoteControl.heartbeatPayload()
            let frame = CloudHeartbeat(sequence: sequence, sentAt: ISO8601DateFormatter().string(from: .now), agentVersion: "0.1.0", commandAcks: payload.acks, jobs: payload.jobs)
            let data = try JSONEncoder.cloud.encode(frame)
            try await task.send(.data(data))
            let response = try await task.receive()
            let responseData: Data
            switch response { case let .data(data): responseData = data; case let .string(text): responseData = Data(text.utf8); @unknown default: throw CloudDeviceError.invalidResponse }
            guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any], object["version"] as? Int == 1 else { throw CloudDeviceError.invalidResponse }
            if object["type"] as? String == "reconnect-requested", object["reason"] as? String == "lease_expired" {
                task.cancel(with: .goingAway, reason: nil)
                if socket === task { socket = nil }
                throw CloudPresenceConnectionError.serverRequestedReconnect
            }
            guard object["type"] as? String == "heartbeat-accepted", object["sequence"] as? Int == sequence else { throw CloudDeviceError.invalidResponse }
            if let acknowledgements = try? JSONSerialization.data(withJSONObject: object["acknowledgedCommandAcks"] ?? []), let decoded = try? JSONDecoder.cloud.decode([CloudRemoteCommandAck].self, from: acknowledgements) { await remoteControl.acknowledgedByCloud(decoded) }
            if let commandObject = object["command"], !(commandObject is NSNull), let commandData = try? JSONSerialization.data(withJSONObject: commandObject), let command = try? JSONDecoder.cloud.decode(CloudRemoteCommand.self, from: commandData) { await remoteControl.handle(command) }
            sequence += 1
            try await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
        }
    }
}
