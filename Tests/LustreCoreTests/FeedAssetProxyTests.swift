import XCTest
@testable import LustreAgent
@testable import LustreCore

final class FeedAssetProxyTests: XCTestCase {
    func testPornHubImageUsesFixedProviderContextAndReturnsImage() async throws {
        actor Capture {
            var headers: [String: String] = [:]
            func record(_ headers: [String: String]) { self.headers = headers }
            func value() -> [String: String] { headers }
        }
        let capture = Capture()
        let url = URL(string: "https://thumbs.phncdn.com/thumb.mp4/cover.jpg")!
        let proxy = FeedAssetProxy(fetch: { requestURL, headers, _ in
            await capture.record(headers)
            return FeedAssetResponse(data: Data([1]), contentType: "image/jpeg", finalURL: requestURL)
        })

        let asset = try await proxy.load(url: url, kind: .image)

        XCTAssertEqual(asset.contentType, "image/jpeg")
        let headers = await capture.value()
        XCTAssertEqual(headers["Referer"], "https://www.pornhub.com/")
        XCTAssertEqual(headers["User-Agent"], NetworkConstants.chromeUserAgent)
        XCTAssertNil(headers["Cookie"])
    }

    func testHQPornerVideoRejectsUnsafeRedirectAndUnexpectedContentType() async throws {
        let url = URL(string: "https://cdn.fastporndelivery.com/preview.webm")!
        let unsafeRedirect = FeedAssetProxy(fetch: { _, _, _ in
            FeedAssetResponse(data: Data([1]), contentType: "video/webm", finalURL: URL(string: "https://attacker.example/preview.webm")!)
        })
        await XCTAssertFeedAssetError(try await unsafeRedirect.load(url: url, kind: .video))

        let wrongType = FeedAssetProxy(fetch: { requestURL, _, _ in
            FeedAssetResponse(data: Data("html".utf8), contentType: "text/html", finalURL: requestURL)
        })
        await XCTAssertFeedAssetError(try await wrongType.load(url: url, kind: .video))
    }

    func testRejectsNonHTTPSAndNonProviderAssetURLsBeforeFetching() async throws {
        let proxy = FeedAssetProxy(fetch: { _, _, _ in
            XCTFail("The proxy must not fetch rejected URLs")
            return FeedAssetResponse(data: Data(), contentType: "image/jpeg", finalURL: URL(string: "https://thumbs.phncdn.com/never.jpg")!)
        })

        for url in [URL(string: "http://thumbs.phncdn.com/cover.jpg")!, URL(string: "https://127.0.0.1/cover.jpg")!, URL(string: "https://phncdn.com.attacker.example/cover.jpg")!] {
            await XCTAssertFeedAssetError(try await proxy.load(url: url, kind: .image))
        }
    }
}

private func XCTAssertFeedAssetError<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected feed asset proxy failure", file: file, line: line)
    } catch {
    }
}
