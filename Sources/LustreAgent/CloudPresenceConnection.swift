import Foundation
import LustreCore

private enum CloudPresenceConnectionError: Error {
    case serverRequestedReconnect
    case timedOut
    case invalidHeartbeatResponse(Int)
    case httpStatus(Int)
}

private enum CloudPresenceFailureStage: String {
    case enrollment = "enrollment"
    case sessionChallenge = "session_challenge"
    case signing = "signing"
    case sessionCompletion = "session_completion"
    case gatewayProbe = "gateway_probe"
    case firstHeartbeat = "first_heartbeat"

    func code(for error: Error) -> String {
        if case CloudPresenceConnectionError.timedOut = error { return "timeout" }
        if case let CloudPresenceConnectionError.invalidHeartbeatResponse(count) = error { return "invalid_response_\(count)" }
        if case let CloudPresenceConnectionError.httpStatus(status) = error { return "http_\(status)" }
        if case CloudDeviceError.keychainFailure = error { return "keychain_unavailable" }
        if case CloudDeviceError.deviceRevoked = error { return "device_revoked" }
        if case CloudDeviceError.server = error { return "server_rejected" }
        if let error = error as? URLError { return "url_\(error.code.rawValue)" }
        let error = error as NSError
        if error.code != 0 { return "error_\(error.domain)_\(error.code)" }
        return "failed"
    }
}

public actor CloudPresenceConnection {
    public static let heartbeatInterval: TimeInterval = 30
    private static let maximumHeartbeatFrameBytes = 131_072
    private static let commandDeliveryCapability = "command-delivery-v1"
    private static let feedPageCapability = "feed-page-v1"
    private static let destinationsListCapability = "destinations-list-v1"
    private static let feedQueueCapability = "feed-queue-v1"
    private static let commandWakeCapability = "command-wake-v1"
    private let identity: DeviceIdentity
    private let session: URLSession
    private let remoteControl: CloudRemoteControl
    private var runner: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var reconnectState = CloudPresenceReconnectStateMachine()

    public init(service: AgentService, identity: DeviceIdentity = DeviceIdentity(), session: URLSession? = nil) { self.identity = identity; self.session = session ?? Self.realtimeSession(); remoteControl = CloudRemoteControl(service: service) }

    private static func realtimeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }

    public func startIfEnrolled() {
        guard runner == nil, let enrollment = try? DeviceEnrollmentStore.load() else { return }
        runner = Task { await run(enrollment) }
    }

    public func stop() { runner?.cancel(); runner = nil; reconnectState.stop(); socket?.cancel(with: .goingAway, reason: nil); socket = nil }

    private func run(_ enrollment: CloudEnrollmentMetadata) async {
        while !Task.isCancelled {
            guard let generation = reconnectState.beginConnection() else { return }
            var reconnectReason = CloudPresenceReconnectReason.sessionAuthenticationFailed
            var stage = CloudPresenceFailureStage.enrollment
            do {
                guard reconnectState.requiresFreshSessionToken(for: generation) else { return }
                let client = try CloudEnrollmentClient(origin: URL(string: enrollment.cloudOrigin)!)
                stage = .sessionChallenge
                let challenge = try await timed(after: 15) { try await client.deviceSessionChallenge(deviceID: enrollment.deviceID) }
                stage = .signing
                let envelope = try await timed(after: 10) { try CloudDeviceProtocol.envelope(purpose: "session", audience: enrollment.cloudOrigin, subjectID: enrollment.deviceID.uuidString.lowercased(), nonce: challenge.nonce, thumbprint: try self.identity.thumbprint(), expiresAt: challenge.expiresAt) }
                let signature = try await timed(after: 10) { try self.identity.sign(envelope) }
                stage = .sessionCompletion
                let completed = try await timed(after: 15) { try await client.completeDeviceSession(deviceID: enrollment.deviceID, challengeID: challenge.challengeID, signature: signature) }
                reconnectReason = .transportClosed
                if let gatewayOrigin = completed.gatewayOrigin {
                    stage = .gatewayProbe
                    try await timed(after: 10) { try await self.probeGateway(origin: gatewayOrigin, token: completed.accessToken) }
                    try await timed(after: 10) { try await self.smokeGateway(origin: gatewayOrigin, token: completed.accessToken, target: "_ws-smoke-worker") }
                    try await timed(after: 45) { try await self.smokeGateway(origin: gatewayOrigin, token: completed.accessToken, target: "_ws-smoke-do") }
                }
                stage = .firstHeartbeat
                try await self.connect(origin: completed.gatewayOrigin ?? enrollment.cloudOrigin, token: completed.accessToken, generation: generation, usesGateway: completed.gatewayOrigin != nil)
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
                fputs("Lustre Cloud presence failure: stage=\(stage.rawValue) code=\(stage.code(for: error)) generation=\(generation).\n", stderr)
                fputs(reconnectReason.logMessage(generation: generation, retryDelay: delay) + "\n", stderr)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func connect(origin: String, token: String, generation: CloudPresenceReconnectStateMachine.Generation, usesGateway: Bool) async throws {
        guard reconnectState.requiresFreshSessionToken(for: generation) else { return }
        guard var components = URLComponents(string: origin) else { throw CloudDeviceError.invalidOrigin }
        switch components.scheme?.lowercased() {
        case "https", "wss": components.scheme = "wss"
        case "http", "ws": components.scheme = "ws"
        default: throw CloudDeviceError.invalidOrigin
        }
        components.path = usesGateway ? "/realtime" : "/api/cloud/v1/realtime"
        components.query = nil
        guard let url = components.url else { throw CloudDeviceError.invalidOrigin }
        let task = session.webSocketTask(with: url, protocols: ["lustre-v1", "lustre.\(token)"])
        fputs("Lustre Cloud presence connecting: generation=\(generation).\n", stderr)
        socket = task; task.resume()
        let mailbox = CloudWebSocketMailbox()
        let receivePump = Task {
            do {
                while !Task.isCancelled {
                    switch try await task.receive() {
                    case let .data(data): await mailbox.offer(.data(data))
                    case let .string(text): await mailbox.offer(.text(text))
                    @unknown default: throw CloudDeviceError.invalidResponse
                    }
                }
            } catch {
                await mailbox.finish(error)
            }
        }
        defer { receivePump.cancel() }
        if usesGateway {
            let hello: CloudWebSocketMessage
            do {
                fputs("Lustre Cloud gateway: event=realtime_hello_send_started.\n", stderr)
                try await task.send(.string("{\"version\":1,\"type\":\"gateway_hello\",\"capabilities\":[\"\(Self.commandDeliveryCapability)\",\"\(Self.feedPageCapability)\",\"\(Self.destinationsListCapability)\",\"\(Self.feedQueueCapability)\",\"\(Self.commandWakeCapability)\"]}"))
                hello = try await receiveExpected(type: "gateway_hello_ack", from: mailbox, commandWakeV1: false, timeout: 15)
                fputs("Lustre Cloud gateway: event=realtime_hello_reply_received.\n", stderr)
            } catch {
                if let response = task.response as? HTTPURLResponse { throw CloudPresenceConnectionError.httpStatus(response.statusCode) }
                throw error
            }
            guard let helloFrame = try? JSONDecoder.cloud.decode(CloudGatewayHelloResponse.self, from: hello.data),
                  helloFrame.version == 1,
                  helloFrame.type == "gateway_hello_ack"
            else { throw CloudDeviceError.invalidResponse }
            let commandDeliveryV1 = helloFrame.capabilities?.contains(Self.commandDeliveryCapability) == true
            let feedPageV1 = commandDeliveryV1 && helloFrame.capabilities?.contains(Self.feedPageCapability) == true
            let destinationsListV1 = commandDeliveryV1 && helloFrame.capabilities?.contains(Self.destinationsListCapability) == true
            let feedQueueV1 = commandDeliveryV1 && helloFrame.capabilities?.contains(Self.feedQueueCapability) == true
            let commandWakeV1 = commandDeliveryV1 && helloFrame.capabilities?.contains(Self.commandWakeCapability) == true
            fputs("Lustre Cloud gateway: event=realtime_hello_accepted commandDelivery=\(commandDeliveryV1) feedPage=\(feedPageV1) destinationsList=\(destinationsListV1) feedQueue=\(feedQueueV1) commandWake=\(commandWakeV1).\n", stderr)
            try await heartbeatLoop(task: task, mailbox: mailbox, generation: generation, commandDeliveryV1: commandDeliveryV1, feedPageV1: feedPageV1, destinationsListV1: destinationsListV1, feedQueueV1: feedQueueV1, commandWakeV1: commandWakeV1)
            return
        }
        try await heartbeatLoop(task: task, mailbox: mailbox, generation: generation, commandDeliveryV1: false, feedPageV1: false, destinationsListV1: false, feedQueueV1: false, commandWakeV1: false)
    }

    private func heartbeatLoop(task: URLSessionWebSocketTask, mailbox: CloudWebSocketMailbox, generation: CloudPresenceReconnectStateMachine.Generation, commandDeliveryV1: Bool, feedPageV1: Bool, destinationsListV1: Bool, feedQueueV1: Bool, commandWakeV1: Bool) async throws {
        var sequence = 1
        let correlationID = UUID().uuidString.lowercased()
        while !Task.isCancelled {
            if commandWakeV1 {
                _ = await mailbox.consumeWake()
            }
            guard reconnectState.maySendHeartbeat(for: generation) else {
                task.cancel(with: .goingAway, reason: nil)
                return
            }
            let payload = await remoteControl.heartbeatPayload()
            let data = try heartbeatData(sequence: sequence, correlationID: correlationID, acknowledgements: payload.acks, jobs: payload.jobs)
            fputs("Lustre Cloud gateway: event=realtime_heartbeat_send_started sequence=\(sequence) bytes=\(data.count).\n", stderr)
            try await task.send(.data(data))
            let response = try await receiveExpected(type: "heartbeat-accepted", from: mailbox, commandWakeV1: commandWakeV1, timeout: 15)
            fputs("Lustre Cloud gateway: event=realtime_heartbeat_reply_received sequence=\(sequence).\n", stderr)
            let responseData: Data
            responseData = response.data
            let responseFrame: CloudHeartbeatResponse
            do { responseFrame = try JSONDecoder.cloud.decode(CloudHeartbeatResponse.self, from: responseData) }
            catch { throw CloudPresenceConnectionError.invalidHeartbeatResponse(responseData.count) }
            guard responseFrame.version == 1 else { throw CloudDeviceError.invalidResponse }
            if responseFrame.type == "reconnect-requested", responseFrame.reason == "lease_expired" {
                task.cancel(with: .goingAway, reason: nil)
                if socket === task { socket = nil }
                throw CloudPresenceConnectionError.serverRequestedReconnect
            }
            guard responseFrame.type == "heartbeat-accepted", responseFrame.sequence == sequence else { throw CloudDeviceError.invalidResponse }
            await remoteControl.acknowledgedByCloud(responseFrame.acknowledgedCommandAcks ?? [])
            let command: CloudRemoteCommand?
            if commandDeliveryV1 {
                let deliveryMessage = try await receiveExpected(type: "command-delivery", from: mailbox, commandWakeV1: commandWakeV1, timeout: 10)
                fputs("Lustre Cloud gateway: event=realtime_delivery_received sequence=\(sequence).\n", stderr)
                let deliveryData: Data
                deliveryData = deliveryMessage.data
                guard let delivery = try? JSONDecoder.cloud.decode(CloudCommandDelivery.self, from: deliveryData),
                      delivery.version == 1,
                      delivery.type == "command-delivery",
                      delivery.sequence == sequence,
                      delivery.correlationID == correlationID,
                      delivery.command == nil || delivery.command?.kind == "feed_sites" || (feedPageV1 && delivery.command?.kind == "feed_page") || (destinationsListV1 && delivery.command?.kind == "destinations_list") || (feedQueueV1 && delivery.command?.kind == "queue_url")
                else { throw CloudDeviceError.invalidResponse }
                await remoteControl.acknowledgedByCloud(ids: delivery.acknowledgedCommandAckIDs)
                command = delivery.command
            } else {
                command = responseFrame.command
            }
            let handledCommand = await remoteControl.handle(command)
            sequence += 1
            if handledCommand { continue }
            if commandWakeV1, await mailbox.consumeWake() { continue }
            do {
                let message = try await timedMessage(from: mailbox, after: Self.heartbeatInterval)
                guard commandWakeV1, frameType(message) == "command-available" else { throw CloudDeviceError.invalidResponse }
                _ = await mailbox.consumeWake()
            } catch CloudPresenceConnectionError.timedOut {
                continue
            }
        }
    }

    private func receiveExpected(type: String, from mailbox: CloudWebSocketMailbox, commandWakeV1: Bool, timeout: TimeInterval) async throws -> CloudWebSocketMessage {
        while true {
            let message = try await timedMessage(from: mailbox, after: timeout)
            let receivedType = frameType(message)
            if receivedType == type { return message }
            if commandWakeV1, receivedType == "command-available" { continue }
            throw CloudDeviceError.invalidResponse
        }
    }

    private func frameType(_ message: CloudWebSocketMessage) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: message.data) as? [String: Any],
              object["version"] as? Int == 1
        else { return nil }
        return object["type"] as? String
    }

    private func timedMessage(from mailbox: CloudWebSocketMailbox, after seconds: TimeInterval) async throws -> CloudWebSocketMessage {
        try await withThrowingTaskGroup(of: CloudWebSocketMessage.self) { group in
            group.addTask { try await mailbox.next() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CloudPresenceConnectionError.timedOut
            }
            defer { group.cancelAll() }
            guard let message = try await group.next() else { throw CloudPresenceConnectionError.timedOut }
            return message
        }
    }

    private func probeGateway(origin: String, token: String) async throws {
        guard var components = URLComponents(string: origin) else { throw CloudDeviceError.invalidOrigin }
        components.scheme = components.scheme == "wss" ? "https" : components.scheme == "ws" ? "http" : components.scheme
        components.path = "/probe"
        components.query = nil
        guard let url = components.url else { throw CloudDeviceError.invalidOrigin }
        var request = URLRequest(url: url)
        request.setValue("lustre-v1, lustre.\(token)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudDeviceError.invalidResponse }
        guard http.statusCode == 200 else { throw CloudPresenceConnectionError.httpStatus(http.statusCode) }
    }

    private func heartbeatData(sequence: Int, correlationID: String, acknowledgements: [CloudRemoteCommandAck], jobs: [CloudRemoteJobStatus]) throws -> Data {
        let sentAt = ISO8601DateFormatter().string(from: .now)
        var included: [CloudRemoteJobStatus] = []
        var encoded = try JSONEncoder.cloud.encode(CloudHeartbeat(sequence: sequence, sentAt: sentAt, agentVersion: "0.1.0", correlationID: correlationID, commandAcks: acknowledgements, jobs: included))
        guard encoded.count <= Self.maximumHeartbeatFrameBytes else { throw CloudDeviceError.invalidResponse }
        for job in jobs {
            let candidate = included + [job]
            let candidateData = try JSONEncoder.cloud.encode(CloudHeartbeat(sequence: sequence, sentAt: sentAt, agentVersion: "0.1.0", correlationID: correlationID, commandAcks: acknowledgements, jobs: candidate))
            guard candidateData.count <= Self.maximumHeartbeatFrameBytes else { break }
            included = candidate
            encoded = candidateData
        }
        return encoded
    }

    private func smokeGateway(origin: String, token: String, target: String) async throws {
        guard var components = URLComponents(string: origin) else { throw CloudDeviceError.invalidOrigin }
        components.scheme = components.scheme == "https" ? "wss" : components.scheme == "http" ? "ws" : components.scheme
        components.path = "/\(target)"
        components.query = nil
        guard let url = components.url else { throw CloudDeviceError.invalidOrigin }
        fputs("Lustre Cloud gateway smoke: target=\(target) event=connecting.\n", stderr)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = target == "_ws-smoke-do" ? 45 : 15
        let smokeSession = URLSession(configuration: configuration)
        let task = smokeSession.webSocketTask(with: url, protocols: ["lustre-v1", "lustre.\(token)"])
        task.resume()
        do {
            let reply = try await sendAndReceive(.string("{\"version\":1,\"type\":\"gateway_hello\"}"), using: task)
            guard case let .string(text) = reply, text.contains("gateway_hello_ack") else { throw CloudDeviceError.invalidResponse }
            fputs("Lustre Cloud gateway smoke: target=\(target) event=hello_ack.\n", stderr)
            if target == "_ws-smoke-do" {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                let heartbeat = Data("{\"version\":1,\"type\":\"heartbeat\",\"sequence\":1,\"sentAt\":\"2026-01-01T00:00:00Z\",\"agentVersion\":\"smoke\",\"correlationID\":\"smoke\",\"commandAcks\":[],\"jobs\":[]}".utf8)
                fputs("Lustre Cloud gateway smoke: target=\(target) event=heartbeat_data_send_started.\n", stderr)
                try await task.send(.data(heartbeat))
                fputs("Lustre Cloud gateway smoke: target=\(target) event=heartbeat_data_send_completed.\n", stderr)
                let heartbeatReply = try await task.receive()
                guard case let .string(heartbeatText) = heartbeatReply,
                      heartbeatText.contains("\"type\":\"heartbeat-accepted\""),
                      heartbeatText.contains("\"sequence\":1")
                else { throw CloudDeviceError.invalidResponse }
                fputs("Lustre Cloud gateway smoke: target=\(target) event=heartbeat_reply_received.\n", stderr)
            }
        } catch {
            if let response = task.response as? HTTPURLResponse { throw CloudPresenceConnectionError.httpStatus(response.statusCode) }
            throw error
        }
        task.cancel(with: .goingAway, reason: nil)
    }

    private func sendAndReceive(_ message: URLSessionWebSocketTask.Message, using task: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        let timeout = Task.detached {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }
        try await task.send(message)
        return try await task.receive()
    }

    private func receive(using task: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        let timeout = Task.detached {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }
        return try await task.receive()
    }

    private func timed<T: Sendable>(after seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw CloudPresenceConnectionError.timedOut }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CloudPresenceConnectionError.timedOut }
            return result
        }
    }
}
