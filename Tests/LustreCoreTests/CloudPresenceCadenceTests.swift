import XCTest
@testable import LustreAgent
@testable import LustreCore

final class CloudPresenceCadenceTests: XCTestCase {
    func testUsesTwoSecondHeartbeatWhileTransferIsActive() throws {
        var job = DownloadJob(sourcePageURL: try XCTUnwrap(URL(string: "https://example.com/video")), status: .running)
        job.transferPhase = .uploading

        XCTAssertEqual(CloudPresenceConnection.nextHeartbeatInterval(for: [CloudRemoteJobStatus(job)]), 2)

        job.status = .completed
        XCTAssertEqual(CloudPresenceConnection.nextHeartbeatInterval(for: [CloudRemoteJobStatus(job)]), 30)
    }
}
