import Foundation
import XCTest
@testable import LustreAgent
@testable import LustreCore

final class CloudRemoteControlFeedPageTests: XCTestCase {
    func testFeedPageAcknowledgementUsesExactByteBoundary() throws {
        let id = UUID()
        func acknowledgement(titleLength: Int) -> CloudRemoteCommandAck {
            let item = FeedItem(
                id: "item",
                siteID: .hqPorner,
                title: String(repeating: "x", count: titleLength),
                sourcePageURL: URL(string: "https://example.com/video")!,
                thumbnailURL: nil,
                previewURLs: [],
                uploadedAt: Date(timeIntervalSince1970: 0),
                viewCount: 0,
                studio: nil,
                queueCapability: .supported
            )
            return CloudRemoteControl.boundedFeedPageAcknowledgement(id: id, page: FeedPage(items: [item], page: 1, hasMore: false))
        }

        var low = 0
        var high = CloudRemoteControl.maximumFeedPageAcknowledgementBytes
        while low < high {
            let middle = (low + high + 1) / 2
            let encoded = try JSONEncoder.cloud.encode(acknowledgement(titleLength: middle))
            if encoded.count <= CloudRemoteControl.maximumFeedPageAcknowledgementBytes && acknowledgement(titleLength: middle).status == "completed" {
                low = middle
            } else {
                high = middle - 1
            }
        }

        let boundary = acknowledgement(titleLength: low)
        XCTAssertEqual(boundary.status, "completed")
        XCTAssertEqual(try JSONEncoder.cloud.encode(boundary).count, CloudRemoteControl.maximumFeedPageAcknowledgementBytes)
        XCTAssertEqual(acknowledgement(titleLength: low + 1).status, "failed")
    }

    func testPendingAcknowledgementsDeduplicateReceiptReplayByCommandID() {
        let id = UUID()
        let acknowledgement = CloudRemoteCommandAck(id: id, status: "failed", jobID: nil, result: nil)
        var pending = [acknowledgement]
        CloudRemoteControl.appendAcknowledgement(acknowledgement, to: &pending)
        XCTAssertEqual(pending.map(\.id), [id])
    }
}
