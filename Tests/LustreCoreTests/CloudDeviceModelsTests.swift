import XCTest
@testable import LustreCore
@testable import LustreAgent

final class CloudDeviceModelsTests: XCTestCase {
    func testNormalizesGroupedPairingCode() throws {
        XCTAssertEqual(try CloudDeviceProtocol.normalizePairingCode("abcde-fghjk-mnpqr-stvwz"), "ABCDEFGHJKMNPQRSTVWZ")
        XCTAssertThrowsError(try CloudDeviceProtocol.normalizePairingCode("0000"))
    }

    func testEnvelopeIsDomainSeparated() throws {
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)
        let nonce = Data(repeating: 1, count: 32).base64EncodedString()
        let enrollment = try CloudDeviceProtocol.envelope(purpose: "enrollment", audience: "https://app.example", subjectID: "one", nonce: nonce, thumbprint: "thumb", expiresAt: expiry)
        let session = try CloudDeviceProtocol.envelope(purpose: "session", audience: "https://app.example", subjectID: "one", nonce: nonce, thumbprint: "thumb", expiresAt: expiry)
        XCTAssertNotEqual(enrollment, session)
    }

    func testCloudDecoderAcceptsJavaScriptMillisecondTimestamp() throws {
        let value = try JSONDecoder.cloud.decode(CloudEnrollmentChallenge.self, from: Data("{\"protocolVersion\":1,\"enrollmentID\":\"a1a5059c-35e3-40db-86e5-fd229c5c3a64\",\"nonce\":\"wB1CdOQSI4c0w3HUD1FCn0oCOcIjJk8F3oQkoHtmVqk=\",\"expiresAt\":\"2026-07-25T05:56:32.608Z\"}".utf8))
        XCTAssertEqual(value.expiresAt.timeIntervalSince1970, 1_784_958_992.608, accuracy: 0.001)
    }

    func testUUIDSubjectsUseTheServerCanonicalLowercaseForm() {
        XCTAssertEqual(UUID(uuidString: "A1A5059C-35E3-40DB-86E5-FD229C5C3A64")!.uuidString.lowercased(), "a1a5059c-35e3-40db-86e5-fd229c5c3a64")
    }

    func testReconnectRequiresFreshSessionTokenForEveryGeneration() {
        var state = CloudPresenceReconnectStateMachine(jitter: { $0 })
        let first = state.beginConnection()!
        XCTAssertTrue(state.requiresFreshSessionToken(for: first))

        _ = state.connectionFailed(first)
        let second = state.beginConnection()!
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(state.requiresFreshSessionToken(for: second))
    }

    func testReconnectBackoffIsBoundedAndUsesInjectedJitter() {
        var state = CloudPresenceReconnectStateMachine(jitter: { _ in 0.25 })
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            let generation = state.beginConnection()!
            delays.append(state.connectionFailed(generation)!)
        }

        XCTAssertEqual(delays, [1.2, 2.25, 4.25, 8.25, 16.25, 32.25, 60.25, 60.25])
        XCTAssertTrue(delays.allSatisfy { $0 <= 63 })
    }

    func testOnlyCurrentGenerationMayHeartbeat() {
        var state = CloudPresenceReconnectStateMachine(jitter: { $0 })
        let first = state.beginConnection()!
        XCTAssertTrue(state.maySendHeartbeat(for: first))
        XCTAssertNil(state.beginConnection())

        _ = state.connectionFailed(first)
        let second = state.beginConnection()!
        XCTAssertFalse(state.maySendHeartbeat(for: first))
        XCTAssertTrue(state.maySendHeartbeat(for: second))
    }

    func testRevokedDeviceStopsReconnectsAndHeartbeatLoops() {
        var state = CloudPresenceReconnectStateMachine(jitter: { $0 })
        let generation = state.beginConnection()!
        state.stopForRevocation()

        XCTAssertFalse(state.maySendHeartbeat(for: generation))
        XCTAssertNil(state.connectionFailed(generation))
        XCTAssertNil(state.beginConnection())
    }

    func testLeaseReconnectUsesFreshGenerationAndBlocksTheStaleHeartbeatLoop() {
        var state = CloudPresenceReconnectStateMachine(jitter: { _ in 0 })
        let leasedGeneration = state.beginConnection()!
        XCTAssertTrue(state.requiresFreshSessionToken(for: leasedGeneration))

        XCTAssertEqual(state.connectionFailed(leasedGeneration), 1)
        let replacementGeneration = state.beginConnection()!
        XCTAssertNotEqual(leasedGeneration, replacementGeneration)
        XCTAssertTrue(state.requiresFreshSessionToken(for: replacementGeneration))
        XCTAssertFalse(state.maySendHeartbeat(for: leasedGeneration))
        XCTAssertTrue(state.maySendHeartbeat(for: replacementGeneration))
    }

    func testLeaseReconnectLogsOnlyItsSafeReasonAndRevocationWins() {
        var state = CloudPresenceReconnectStateMachine(jitter: { _ in 0 })
        let generation = state.beginConnection()!
        let message = CloudPresenceReconnectReason.serverRequestedReconnect.logMessage(generation: generation, retryDelay: state.connectionFailed(generation)!)
        XCTAssertEqual(message, "Lustre Cloud presence reconnecting: reason=server_requested_reconnect generation=1 retryDelaySeconds=1.000.")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("ws://"))

        let scheduledGeneration = state.beginConnection()!
        state.stopForRevocation()
        XCTAssertNil(state.connectionFailed(scheduledGeneration))
        XCTAssertNil(state.beginConnection())
    }
}
