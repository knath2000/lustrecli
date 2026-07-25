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
}
