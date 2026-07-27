import Foundation
import XCTest
@testable import LustreAgent
@testable import LustreCore

final class CloudRemoteControlDestinationsTests: XCTestCase {
    func testDestinationsAreDeterministicAndSecretFree() throws {
        let first = try profile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, name: "Zulu")
        let second = try profile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, name: "alpha")
        let acknowledgement = CloudRemoteControl.boundedDestinationsAcknowledgement(id: UUID(), profiles: [first, second])
        XCTAssertEqual(acknowledgement.status, "completed")
        XCTAssertEqual(acknowledgement.result?.destinations?.map(\.name), ["alpha", "Zulu"])
        let encoded = String(decoding: try JSONEncoder.cloud.encode(acknowledgement), as: UTF8.self)
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("token"))
    }

    func testDestinationAcknowledgementRejectsCountAndExactByteOverflow() throws {
        let commandID = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
        var exactProfiles: [WebDAVDestinationProfile]?
        for fixedCount in 1..<CloudRemoteControl.maximumDestinations where exactProfiles == nil {
            let fixed = try (0..<fixedCount).map {
                try profile(
                    id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0 + 1))!,
                    name: String(repeating: "n", count: 128),
                    username: String(repeating: "u", count: 256),
                    remotePath: "/" + String(repeating: "p", count: 1_023)
                )
            }
            let minimum = try profile(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000098")!,
                name: String(repeating: "a", count: 128),
                username: String(repeating: "u", count: 256),
                remotePath: "/q"
            )
            let minimumLength = try JSONEncoder.cloud.encode(CloudRemoteControl.boundedDestinationsAcknowledgement(id: commandID, profiles: fixed + [minimum])).count
            let pathLength = CloudRemoteControl.maximumDestinationsAcknowledgementBytes - minimumLength + 1
            guard (1..<1_024).contains(pathLength) else { continue }
            let adjustable = try profile(
                id: minimum.id,
                name: minimum.name,
                username: minimum.username,
                remotePath: "/" + String(repeating: "q", count: pathLength)
            )
            let acknowledgement = CloudRemoteControl.boundedDestinationsAcknowledgement(id: commandID, profiles: fixed + [adjustable])
            if acknowledgement.status == "completed",
               try JSONEncoder.cloud.encode(acknowledgement).count == CloudRemoteControl.maximumDestinationsAcknowledgementBytes {
                exactProfiles = fixed + [adjustable]
            }
        }
        let exact = try XCTUnwrap(exactProfiles)
        XCTAssertEqual(try JSONEncoder.cloud.encode(CloudRemoteControl.boundedDestinationsAcknowledgement(id: commandID, profiles: exact)).count, CloudRemoteControl.maximumDestinationsAcknowledgementBytes)
        let last = try XCTUnwrap(exact.last)
        let over = try profile(id: last.id, name: last.name, username: last.username, remotePath: last.remotePath + "q")
        XCTAssertEqual(CloudRemoteControl.boundedDestinationsAcknowledgement(id: commandID, profiles: exact.dropLast() + [over]).status, "failed")
        let maximumCount = try (0..<CloudRemoteControl.maximumDestinations).map {
            try profile(id: UUID(), name: "Destination \($0)")
        }
        XCTAssertEqual(CloudRemoteControl.boundedDestinationsAcknowledgement(id: commandID, profiles: maximumCount + [try profile(id: UUID(), name: "Overflow")]).status, "failed")
    }

    func testDestinationReceiptReplayDeduplicatesByCommandID() {
        let id = UUID()
        let acknowledgement = CloudRemoteCommandAck(id: id, status: "completed", jobID: nil, result: nil)
        var pending = [acknowledgement]
        CloudRemoteControl.appendAcknowledgement(acknowledgement, to: &pending)
        XCTAssertEqual(pending.map(\.id), [id])
    }

    private func profile(id: UUID, name: String, username: String = "user", remotePath: String = "/remote") throws -> WebDAVDestinationProfile {
        try WebDAVDestinationProfile(id: id, name: name, baseURL: URL(string: "https://dav.example.com")!, username: username, remotePath: remotePath)
    }
}
