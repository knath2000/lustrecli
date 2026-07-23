import XCTest
@testable import LustreCore

final class OnlyFan420FeedTests: XCTestCase {
    func testParserPreservesSupportedSourceOrderAndDeduplicates() {
        let html = """
        <span style="color:yellow">22 July 2026 -- New</span>
        <a class="external" href="https://playmogo.com/e/alpha">Studio One - Alpha &amp; Beta<img src="https://images.example/alpha.jpg"></a>
        <a class="external ad" href="https://clenchinfer.example/ad">Ad<img src="https://images.example/ad.jpg"></a>
        <a class="external" href="https://sub.vidara.so/v/bravo">Bravo<img src="https://images.example/bravo.jpg"></a>
        <a class="external" href="https://playmogo.com/e/alpha">Duplicate<img src="https://images.example/duplicate.jpg"></a>
        <span style="color:yellow">21 Jul 2026 -- Older</span>
        <a class="external" href="https://luluvdo.com/e/charlie">Charlie<img src="https://images.example/charlie.jpg"></a>
        """
        let page = OnlyFan420FeedParser.parse(html: html)
        XCTAssertEqual(page.items.map(\.title), ["Studio One - Alpha & Beta", "Bravo", "Charlie"])
        XCTAssertEqual(page.items.first?.studio, "Studio One")
        XCTAssertEqual(page.items.map(\.queueCapability), [.supported, .supported, .supported])
        XCTAssertFalse(page.hasMore)
    }

    func testParserRejectsLookalikesMalformedCardsAndUnsafeURLs() {
        let html = """
        <span style="color:yellow">22 July 2026 -- New</span>
        <a class="external" href="https://vidara.so.evil.example/v/a">Lookalike<img src="https://images.example/a.jpg"></a>
        <a class="external" href="https://user@vidara.so/v/b">Credentials<img src="https://images.example/b.jpg"></a>
        <a class="external" href="https://luluvdo.com/e/c">Missing image</a>
        """
        XCTAssertTrue(OnlyFan420FeedParser.parse(html: html).items.isEmpty)
        XCTAssertTrue(OnlyFan420FeedParser.parse(html: "<broken>").items.isEmpty)
    }

    func testOnlyFirstPageFetchesWithRequiredHeaders() async throws {
        actor Capture {
            var calls: [(URL, [String: String])] = []
            func add(_ url: URL, _ headers: [String: String]) { calls.append((url, headers)) }
        }
        let capture = Capture()
        let service = FeedService { url, headers in
            await capture.add(url, headers)
            return HTTPPage(body: "<html></html>", finalURL: url, statusCode: 200)
        }
        _ = try await service.page(site: .onlyFan420, page: 1)
        let second = try await service.page(site: .onlyFan420, page: 2)
        let calls = await capture.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, FeedSite.onlyFan420.homeURL)
        XCTAssertEqual(calls[0].1["Referer"], "https://rentry.co")
        XCTAssertNotNil(calls[0].1["User-Agent"])
        XCTAssertNotNil(calls[0].1["Accept"])
        XCTAssertNotNil(calls[0].1["Accept-Language"])
        XCTAssertEqual(second, FeedPage(items: [], page: 2, hasMore: false))
    }
}
