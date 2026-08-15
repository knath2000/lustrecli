import Foundation
import XCTest
@testable import LustreAgent
@testable import LustreCore

final class CloudRemoteControlFeedPageTests: XCTestCase {
    func testDownloadedFeedHistoryMatchesNormalizedURLAndPornHubViewkey() {
        let downloadedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let history = DownloadedFeedHistory(jobs: [
            DownloadJob(sourcePageURL: URL(string: "https://EXAMPLE.com/video#details")!, status: .completed, updatedAt: downloadedAt),
            DownloadJob(sourcePageURL: URL(string: "https://www.pornhub.com/view_video.php?viewkey=PH123&ref=feed")!, status: .completed, updatedAt: downloadedAt),
            DownloadJob(sourcePageURL: URL(string: "https://example.com/failed")!, status: .failed, updatedAt: downloadedAt),
        ])

        XCTAssertEqual(history.downloadedAt(for: URL(string: "https://example.com/video")!), downloadedAt)
        XCTAssertEqual(history.downloadedAt(for: URL(string: "https://pornhub.com/view_video.php?viewkey=ph123")!), downloadedAt)
        XCTAssertNil(history.downloadedAt(for: URL(string: "https://example.com/failed")!))
    }

    func testPornHubAuthAcknowledgementContainsOnlySafeStatus() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let acknowledgement = CloudRemoteControl.pornHubAuthAcknowledgement(
            id: UUID(),
            status: PornHubAuthStatus(state: .expired, lastValidatedAt: date, message: PornHubAuthError.expired.errorDescription)
        )

        XCTAssertEqual(acknowledgement.result?.pornHubAuth, CloudRemotePornHubAuthStatus(PornHubAuthStatus(state: .expired, lastValidatedAt: date, message: PornHubAuthError.expired.errorDescription)))
        XCTAssertEqual(acknowledgement.result?.pornHubAuth?.code, "expired")
        let encoded = String(decoding: try JSONEncoder.cloud.encode(acknowledgement), as: UTF8.self)
        XCTAssertFalse(encoded.contains(PornHubAuthError.expired.errorDescription!))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("cookie"))
    }
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

    func testGatewayQueuePreservesPreferredQuality() async throws {
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-cloud-queue-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let service = try AgentService(databaseURL: database, automaticallyStartsDownloads: false)
        let control = CloudRemoteControl(service: service)
        let id = UUID()
        let command = CloudRemoteCommand(
            id: id,
            kind: "queue_url",
            payload: CloudRemoteCommand.Payload(
                url: URL(string: "https://allpornstream.com/post/example"),
                preferredQualityLabel: "1080p60",
                destination: "local",
                deliveryProtocol: "gateway-v1",
                jobID: nil,
                action: nil,
                siteID: nil,
                query: nil,
                page: nil,
                name: nil,
                baseURL: nil,
                username: nil,
                remotePath: nil,
                allowInvalidCertificate: nil
            )
        )

        let handled = await control.handle(command)
        let stored = try await service.job(id: id)
        XCTAssertTrue(handled)
        let job = try XCTUnwrap(stored)
        XCTAssertEqual(job.preferredQualityLabel, "1080p60")
        XCTAssertEqual(job.status, .queued)
    }

    func testGatewayRetryAppliesToTerminalJob() async throws {
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-cloud-retry-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let resolver = StaticProviderResolver(
            fetch: { url, _ in HTTPPage(body: "<html></html>", finalURL: url, statusCode: 200) },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let service = try AgentService(databaseURL: database, resolver: resolver, automaticallyStartsDownloads: false)
        let control = CloudRemoteControl(service: service)
        let job = try await service.createJob(CreateJobRequest(sourcePageURL: URL(string: "https://mixdrop.co/e/example")!))
        _ = try await service.apply(.cancel, to: job.id)
        let command = CloudRemoteCommand(
            id: UUID(),
            kind: "job_action",
            payload: CloudRemoteCommand.Payload(
                url: nil,
                preferredQualityLabel: nil,
                destination: nil,
                deliveryProtocol: "gateway-v1",
                jobID: job.id,
                action: .retry,
                siteID: nil,
                query: nil,
                page: nil,
                name: nil,
                baseURL: nil,
                username: nil,
                remotePath: nil,
                allowInvalidCertificate: nil
            )
        )

        let handled = await control.handle(command)
        let stored = try await service.job(id: job.id)
        XCTAssertTrue(handled)
        let retried = try XCTUnwrap(stored)
        XCTAssertNotEqual(retried.status, .cancelled)
        XCTAssertEqual(retried.attempts, 1)
    }
}
