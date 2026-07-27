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

    func testOversizedPreviewSetIsReducedWithoutDroppingFeedItems() throws {
        let items = (0..<50).map { index in
            FeedItem(
                id: "item-\(index)",
                siteID: .allPornStream,
                title: "Item \(index)",
                sourcePageURL: URL(string: "https://allpornstream.com/post/\(index)")!,
                thumbnailURL: URL(string: "https://allpornstream.com/api/images?src=\(String(repeating: "a", count: 200))\(index)")!,
                previewURLs: [
                    URL(string: "https://allpornstream.com/api/images?src=\(String(repeating: "a", count: 200))\(index)")!,
                    URL(string: "https://allpornstream.com/api/images?src=\(String(repeating: "b", count: 800))\(index)-1")!,
                    URL(string: "https://allpornstream.com/api/images?src=\(String(repeating: "b", count: 800))\(index)-2")!,
                    URL(string: "https://allpornstream.com/api/images?src=\(String(repeating: "b", count: 800))\(index)-3")!,
                ],
                uploadedAt: Date(timeIntervalSince1970: 0),
                viewCount: index,
                studio: nil,
                queueCapability: .supported
            )
        }

        let acknowledgement = CloudRemoteControl.boundedFeedPageAcknowledgement(
            id: UUID(),
            page: FeedPage(items: items, page: 1, hasMore: true)
        )

        XCTAssertEqual(acknowledgement.status, "completed")
        XCTAssertEqual(acknowledgement.result?.page?.items.count, 50)
        XCTAssertLessThan(acknowledgement.result?.page?.items.first?.previewURLs.count ?? 4, 4)
        XCTAssertNotEqual(acknowledgement.result?.page?.items.first?.thumbnailURL, acknowledgement.result?.page?.items.first?.previewURLs.first)
        XCTAssertLessThanOrEqual(try JSONEncoder.cloud.encode(acknowledgement).count, CloudRemoteControl.maximumFeedPageAcknowledgementBytes)
    }

    func testAllPornStreamCaptureDoesNotBlockHeartbeatAndDuplicateDeliveryReusesTask() async throws {
        actor Opens {
            var count = 0
            func record() { count += 1 }
        }
        let opens = Opens()
        let capture = AllPornStreamCaptureCoordinator(timeout: 10) { _ in await opens.record() }
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-browser-command-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let service = try AgentService(databaseURL: database, automaticallyStartsDownloads: false, allPornStreamCapture: capture)
        let control = CloudRemoteControl(service: service)
        let command = CloudRemoteCommand(
            id: UUID(),
            kind: "feed_page",
            payload: CloudRemoteCommand.Payload(
                url: nil,
                preferredQualityLabel: nil,
                destination: nil,
                deliveryProtocol: nil,
                jobID: nil,
                action: nil,
                siteID: "allpornstream",
                query: nil,
                page: 1,
                name: nil,
                baseURL: nil,
                username: nil,
                remotePath: nil,
                allowInvalidCertificate: nil
            )
        )

        let firstHandled = await control.handle(command)
        let secondHandled = await control.handle(command)
        XCTAssertFalse(firstHandled)
        XCTAssertFalse(secondHandled)
        _ = await control.heartbeatPayload()
        for _ in 0..<100 {
            if await opens.count == 1 { break }
            await Task.yield()
        }
        let openCount = await opens.count
        XCTAssertEqual(openCount, 1)
        await capture.stop()
    }
}
