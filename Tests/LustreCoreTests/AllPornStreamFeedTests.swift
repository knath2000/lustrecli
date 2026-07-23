import Foundation
import LustreCore
import XCTest

final class AllPornStreamFeedTests: XCTestCase {
    func testParsesStructuredFeedItemsAndPreservesSourceOrder() throws {
        let html = #"""
        <html><body>
        <article data-href="/post/alpha" data-images="https://cdn.example/alpha-1.jpg https://cdn.example/alpha-2.jpg"></article>
        <article data-href="/post/beta"><img src="https://cdn.example/beta.jpg"></article>
        <script type="application/ld+json">
        {
          "@type": "ItemList",
          "itemListElement": [
            {
              "@type": "VideoObject",
              "position": 1,
              "name": "[Studio A] Alpha",
              "url": "/post/alpha",
              "thumbnailUrl": "https://cdn.example/alpha-fallback.jpg",
              "uploadDate": "2026-07-22T10:00:00Z",
              "interactionStatistic": { "userInteractionCount": "1200" }
            },
            {
              "@type": "VideoObject",
              "position": 2,
              "name": "Beta",
              "url": "/post/beta",
              "thumbnailUrl": ["https://cdn.example/beta-fallback.jpg"],
              "uploadDate": "2026-07-21T10:00:00Z",
              "interactionStatistic": { "userInteractionCount": 45 }
            }
          ]
        }
        </script>
        </body></html>
        """#

        let page = try AllPornStreamFeedParser.parse(
            html: html,
            page: 1,
            baseURL: URL(string: "https://allpornstream.com")!
        )

        XCTAssertEqual(page.items.map(\.id), ["alpha", "beta"])
        XCTAssertEqual(page.items[0].sourcePageURL.absoluteString, "https://allpornstream.com/post/alpha")
        XCTAssertEqual(page.items[0].title, "[Studio A] Alpha")
        XCTAssertEqual(page.items[0].studio, "Studio A")
        XCTAssertEqual(page.items[0].viewCount, 1_200)
        XCTAssertEqual(page.items[0].queueCapability, .supported)
        XCTAssertEqual(page.items[0].previewURLs.first?.host, "allpornstream.com")
        XCTAssertEqual(page.items[1].thumbnailURL?.host, "allpornstream.com")
        XCTAssertEqual(page.page, 1)
        XCTAssertTrue(page.hasMore)
    }

    func testRejectsFeedWithoutStructuredVideoList() {
        XCTAssertThrowsError(
            try AllPornStreamFeedParser.parse(
                html: "<html><body>No feed metadata</body></html>",
                page: 1,
                baseURL: URL(string: "https://allpornstream.com")!
            )
        ) { error in
            XCTAssertEqual(error as? FeedError, .missingStructuredData)
        }
    }

    func testFeedServiceRequestsRequestedPageWithSafeHeaders() async throws {
        actor Capture {
            var url: URL?
            var headers: [String: String] = [:]
            func record(url: URL, headers: [String: String]) { self.url = url; self.headers = headers }
            func snapshot() -> (URL?, [String: String]) { (url, headers) }
        }
        let capture = Capture()
        let service = FeedService(fetch: { url, headers in
            await capture.record(url: url, headers: headers)
            return HTTPPage(
                body: #"<script type="application/ld+json">{"@type":"ItemList","itemListElement":[],"itemType":"VideoObject"}</script>"#,
                finalURL: url,
                statusCode: 200
            )
        })

        let page = try await service.page(site: .allPornStream, page: 3)
        let (requestedURL, requestedHeaders) = await capture.snapshot()

        XCTAssertEqual(page.page, 3)
        XCTAssertEqual(requestedURL?.absoluteString, "https://allpornstream.com?page=3")
        XCTAssertNotNil(requestedHeaders["User-Agent"])
        XCTAssertEqual(requestedHeaders["Referer"], "https://allpornstream.com")
    }
}
