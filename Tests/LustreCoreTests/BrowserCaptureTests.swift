import Darwin
import Foundation
import LustreCore
@testable import LustreAgent
import XCTest

final class BrowserCaptureTests: XCTestCase {
    actor OpenedPages {
        var values: [URL] = []
        var waiters: [CheckedContinuation<URL, Never>] = []
        func append(_ url: URL) {
            values.append(url)
            waiters.forEach { $0.resume(returning: url) }
            waiters.removeAll()
        }
        func next() async -> URL {
            if let first = values.first { return first }
            return await withCheckedContinuation { waiters.append($0) }
        }
        func count() -> Int { values.count }
    }

    func testDuplicateCaptureReusesOneTabAndAcceptsBoundedMetadata() async throws {
        let opened = OpenedPages()
        let coordinator = AllPornStreamCaptureCoordinator(timeout: 2) { url in await opened.append(url) }
        let pageURL = URL(string: "https://allpornstream.com?s=test&page=2")!
        async let first = coordinator.capture(url: pageURL, page: 2)
        async let second = coordinator.capture(url: pageURL, page: 2)

        let markedURL = await opened.next()
        let requestID = try XCTUnwrap(
            URLComponents(url: markedURL, resolvingAgainstBaseURL: false)?.fragment?.split(separator: "=").last.flatMap { UUID(uuidString: String($0)) }
        )
        let data = try captureData(requestID: requestID, pageURL: URL(string: "https://allpornstream.com/?s=test&page=2")!)
        let response = await coordinator.receiveForTesting(data)
        XCTAssertEqual(try JSONDecoder().decode(BrowserCaptureResponse.self, from: response).type, "capture_accepted")
        let pages = try await [first, second]
        XCTAssertEqual(pages.map(\.page), [2, 2])
        let openCount = await opened.count()
        XCTAssertEqual(openCount, 1)
    }

    func testUnknownReplayAndWrongHostAreRejected() async throws {
        let coordinator = AllPornStreamCaptureCoordinator(timeout: 0.01) { _ in }
        let unknown = try captureData(requestID: UUID(), pageURL: URL(string: "https://allpornstream.com")!)
        let responseData = await coordinator.receiveForTesting(unknown)
        let response = try JSONDecoder().decode(BrowserCaptureResponse.self, from: responseData)
        XCTAssertEqual(response.type, "capture_rejected")
        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.capture(url: URL(string: "https://example.com")!, page: 1)
        }
    }

    func testNativeFramingUsesBoundedLittleEndianMessages() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        let payload = Data(#"{"type":"feed_capture_v1"}"#.utf8)
        BrowserNativeFraming.write(payload, to: descriptors[0])
        XCTAssertEqual(BrowserNativeFraming.read(from: descriptors[1], maximumBytes: 1024), payload)
    }

    private func captureData(requestID: UUID, pageURL: URL) throws -> Data {
        let capture = BrowserFeedCapture(
            type: "feed_capture_v1",
            version: 1,
            requestID: requestID,
            siteID: "allpornstream",
            pageURL: pageURL,
            capturedAt: .now,
            cards: [BrowserFeedCard(
                title: "[Studio] Test",
                sourcePageURL: URL(string: "https://allpornstream.com/post/test")!,
                thumbnailURL: URL(string: "https://allpornstream.com/api/images?src=https%3A%2F%2Fcdn.example%2Ftest.jpg")!,
                previewURLs: [],
                uploadedAt: .now,
                viewCount: 12,
                studio: nil
            )],
            hasMore: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(capture)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var cards = try XCTUnwrap(object["cards"] as? [[String: Any]])
        cards[0]["uploadedAt"] = "2026-07-26"
        object["cards"] = cards
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error.", file: file, line: line)
    } catch {}
}
