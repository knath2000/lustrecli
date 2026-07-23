import Foundation
import LustreCore
import XCTest

final class HQPornerFeedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_753_200_000)

    func testSiteMetadataAndPageURLContract() throws {
        XCTAssertEqual(FeedSite.hqPorner.id.rawValue, "hqporner")
        XCTAssertEqual(FeedSite.hqPorner.displayName, "HQPorner")
        XCTAssertEqual(FeedSite.hqPorner.homeURL.absoluteString, "https://hqporner.com")
        XCTAssertFalse(FeedSite.hqPorner.supportsSearch)
        XCTAssertTrue(FeedSite.all.contains(.hqPorner))
        XCTAssertEqual(try HQPornerFeedParser.pageURL(page: 1).absoluteString, "https://hqporner.com")
        XCTAssertEqual(try HQPornerFeedParser.pageURL(page: 3).absoluteString, "https://hqporner.com/hdporn/3")
        XCTAssertThrowsError(try HQPornerFeedParser.pageURL(page: 0))
    }

    func testParsesCardsInOrderNormalizesURLsDeduplicatesAndCapsPreviews() throws {
        let html = #"""
        <section class="box feature">
          <a href="/hdporn/101-first-video?ignored=1"><img id="cover_101" src="//img.hqporner.com/101.jpg" alt="Fallback"></a>
          <h3 class="meta-data-title"><a>First &amp; Best</a></h3>
          <button onmouseover="changeImage('//img.hqporner.com/101-1.jpg')"></button>
          <button onmouseover="changeImage('/frames/101-2.jpg')"></button>
          <button onmouseover="changeImage('/frames/101-2.jpg')"></button>
          <button onmouseover="changeImage('/frames/101-3.jpg')"></button>
          <button onmouseover="changeImage('/frames/101-4.jpg')"></button>
          <button onmouseover="changeImage('/frames/101-5.jpg')"></button>
        </section>
        <section class="feature box">
          <a href="https://www.hqporner.com/hdporn/202-second-video"><img src="/202.jpg" id="cover_202" alt="Second Title"></a>
        </section>
        <section class="box feature"><a href="/hdporn/101-first-video"><img src="/duplicate.jpg" alt="Duplicate"></a></section>
        """#

        let page = HQPornerFeedParser.parse(html: html, page: 2, now: now)

        XCTAssertEqual(page.items.map(\.id), ["hqporner-101", "hqporner-202"])
        XCTAssertEqual(page.items.map(\.title), ["First & Best", "Second Title"])
        XCTAssertEqual(page.items[0].sourcePageURL.absoluteString, "https://hqporner.com/hdporn/101-first-video")
        XCTAssertEqual(page.items[1].sourcePageURL.absoluteString, "https://hqporner.com/hdporn/202-second-video")
        XCTAssertEqual(page.items[0].thumbnailURL?.absoluteString, "https://img.hqporner.com/101.jpg")
        XCTAssertEqual(page.items[0].previewURLs.map(\.absoluteString), [
            "https://img.hqporner.com/101-1.jpg",
            "https://hqporner.com/frames/101-2.jpg",
            "https://hqporner.com/frames/101-3.jpg",
            "https://hqporner.com/frames/101-4.jpg"
        ])
        XCTAssertTrue(page.items.allSatisfy { $0.uploadedAt == now && $0.uploadedAtIsApproximate && $0.viewCount == 0 })
        XCTAssertTrue(page.items.allSatisfy { $0.queueCapability == .supported })
        XCTAssertEqual(page.page, 2)
        XCTAssertTrue(page.hasMore)
    }

    func testSkipsMalformedUnsafeAndLookalikeCardsAndHandlesEmptyListing() {
        let html = #"""
        <section class="box feature"><a href="/not-video/1"><img src="/one.jpg" alt="Wrong path"></a></section>
        <section class="box feature"><a href="javascript:alert(1)"><img src="/two.jpg" alt="Unsafe"></a></section>
        <section class="box feature"><a href="https://hqporner.com.attacker.example/hdporn/3-bad"><img src="/three.jpg" alt="Lookalike"></a></section>
        <section class="box feature"><a href="/hdporn/not-numeric"><img src="/four.jpg" alt="No ID"></a></section>
        <section class="box feature"><a href="/hdporn/4-no-title"><img src="/four.jpg"></a></section>
        """#
        XCTAssertTrue(HQPornerFeedParser.parse(html: html, page: 1, now: now).items.isEmpty)
        XCTAssertTrue(HQPornerFeedParser.parse(html: "<main></main>", page: 1, now: now).items.isEmpty)
    }

    func testFeedServiceUsesRequiredHeadersAndRejectsUnsafeOrLookalikeRedirects() async throws {
        actor Capture {
            var url: URL?
            var headers: [String: String] = [:]
            func record(_ url: URL, _ headers: [String: String]) { self.url = url; self.headers = headers }
            func snapshot() -> (URL?, [String: String]) { (url, headers) }
        }
        let capture = Capture()
        let clock = now
        let service = FeedService(fetch: { url, headers in
            await capture.record(url, headers)
            return HTTPPage(body: "<main></main>", finalURL: URL(string: "https://www.hqporner.com/hdporn/4")!, statusCode: 200)
        }, now: { clock })

        let page = try await service.page(site: .hqPorner, page: 4)
        let (requestedURL, requestedHeaders) = await capture.snapshot()
        XCTAssertEqual(page.page, 4)
        XCTAssertEqual(requestedURL?.absoluteString, "https://hqporner.com/hdporn/4")
        XCTAssertEqual(requestedHeaders["User-Agent"], NetworkConstants.chromeUserAgent)
        XCTAssertEqual(requestedHeaders["Referer"], "https://hqporner.com/")
        XCTAssertNotNil(requestedHeaders["Accept"])
        XCTAssertEqual(requestedHeaders["Accept-Language"], "en-US,en;q=0.9")

        for finalURL in [
            URL(string: "http://hqporner.com/hdporn/4")!,
            URL(string: "https://hqporner.com.attacker.example/hdporn/4")!,
            URL(string: "https://attacker.example/hdporn/4")!
        ] {
            let rejecting = FeedService(fetch: { _, _ in HTTPPage(body: "", finalURL: finalURL, statusCode: 200) }, now: { clock })
            await XCTAssertThrowsErrorAsync(try await rejecting.page(site: .hqPorner, page: 4))
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
    }
}
