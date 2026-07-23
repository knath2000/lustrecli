import XCTest
@testable import LustreCore

final class PornHubFeedTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_788_000_000)

    func testParsesPublicCardsInSourceOrderWithCanonicalURLsAndDeduplication() throws {
        let html = """
        <ul>
          <li class="pcVideoListItem" data-video-vkey="ph-first">
            <a href="/view_video.php?viewkey=ph-first" title="First &amp; Best"><img data-src="//thumbs.phncdn.com/first.jpg"></a>
            <video data-mediabook="//cdn.example.net/preview.mp4"></video>
            <var class="duration">1:02:03</var><span class="views"><var>1.2M</var></span>
            <var class="added">2 days ago</var><a href="/pornstar/alice">Alice</a>
          </li>
          <li class="pcVideoListItem" data-video-vkey="ph-second">
            <a href="/view_video.php?viewkey=ph-second" title="Second"><img data-image="https://thumbs.phncdn.com/second.jpg"></a>
            <var class="duration">04:05</var><span class="views"><var>12.5K</var></span>
            <var class="added">Jul 20, 2026</var><a href="/channels/studio">Studio</a>
          </li>
          <li class="pcVideoListItem" data-video-vkey="ph-first"><a title="Duplicate"></a></li>
          <li class="pcVideoListItem advert" data-video-vkey="ad"><a title="Advertisement"></a></li>
          <li class="pcVideoListItem"><a title="Malformed"></a></li>
        </ul>
        <a class="page_next" href="/video?o=ht&amp;page=2">Next</a>
        """
        let page = try PornHubFeedParser.parse(html: html, page: 1, now: clock)
        XCTAssertEqual(page.items.map(\.id), ["pornhub:ph-first", "pornhub:ph-second"])
        XCTAssertEqual(page.items[0].sourcePageURL.absoluteString, "https://www.pornhub.com/view_video.php?viewkey=ph-first")
        XCTAssertEqual(page.items[0].title, "First & Best")
        XCTAssertEqual(page.items[0].thumbnailURL?.absoluteString, "https://thumbs.phncdn.com/first.jpg")
        XCTAssertEqual(page.items[0].previewURLs.map(\.absoluteString), ["https://cdn.example.net/preview.mp4"])
        XCTAssertEqual(page.items[0].viewCount, 1_200_000)
        XCTAssertEqual(page.items[0].studio, "Alice")
        XCTAssertTrue(page.items[0].uploadedAtIsApproximate)
        XCTAssertEqual(page.items[1].viewCount, 12_500)
        XCTAssertFalse(page.items[1].uploadedAtIsApproximate)
        XCTAssertTrue(page.hasMore)
    }

    func testEmptyChallengeIsAnErrorAndPlainEmptyPageEndsPagination() throws {
        XCTAssertThrowsError(try PornHubFeedParser.parse(html: "<title>Just a moment...</title><div>cf-chl</div>", page: 1, now: clock)) {
            XCTAssertEqual($0 as? FeedError, .challengeRequired)
        }
        let page = try PornHubFeedParser.parse(html: "<html><body>No videos found</body></html>", page: 3, now: clock)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertFalse(page.hasMore)
    }

    func testDormantLoginCaptchaMarkupDoesNotHidePublicCards() throws {
        let html = """
        <div class="optional captchaLoginBlock"><div class="g-recaptcha"></div></div>
        <li class="pcVideoListItem" data-video-vkey="ph-public">
          <a href="/view_video.php?viewkey=ph-public" title="Public item"><img data-src="//thumbs.phncdn.com/public.jpg"></a>
        </li>
        """

        let page = try PornHubFeedParser.parse(html: html, page: 1, now: clock)

        XCTAssertEqual(page.items.map(\.id), ["pornhub:ph-public"])
    }

    func testFeedServicePreservesHotSortAndPageAndRejectsLookalikeRedirects() async throws {
        let clock = clock
        let service = FeedService(fetch: { url, headers in
            XCTAssertEqual(url.absoluteString, "https://www.pornhub.com/video?o=ht&page=3")
            XCTAssertEqual(headers["Referer"], "https://www.pornhub.com/")
            XCTAssertNotNil(headers["User-Agent"])
            XCTAssertNil(headers["Cookie"])
            return HTTPPage(body: "<html>No videos found</html>", finalURL: url, statusCode: 200)
        }, now: { clock })
        _ = try await service.page(site: .pornHub, page: 3)

        for finalURL in [
            URL(string: "https://pornhub.com.evil.test/video?o=ht")!,
            URL(string: "http://www.pornhub.com/video?o=ht")!
        ] {
            let rejecting = FeedService(fetch: { _, _ in HTTPPage(body: "", finalURL: finalURL, statusCode: 200) })
            await XCTAssertThrowsErrorAsync(try await rejecting.page(site: .pornHub, page: 1))
        }
    }

    func testAuthenticatedSectionsRequireSessionAndOnlyInjectItForTrustedPornHubURL() async throws {
        let source = URL(string: "https://www.pornhub.com/subscriptions")!
        let signedOut = FeedService(fetch: { _, _ in XCTFail("must not fetch"); return HTTPPage(body: "", finalURL: source, statusCode: 200) }, pornHubCookieHeader: { _ in nil })
        await XCTAssertThrowsErrorAsync(try await signedOut.page(site: .pornHubSubscriptions, page: 1)) { error in
            XCTAssertEqual(error as? FeedError, .authenticationRequired)
        }
        let signedIn = FeedService(fetch: { url, headers in
            XCTAssertEqual(url, source)
            XCTAssertEqual(headers["Cookie"], "il=synthetic")
            return HTTPPage(body: "<li class=\"pcVideoListItem\" data-video-vkey=\"ph-auth\"><a href=\"/view_video.php?viewkey=ph-auth\" title=\"Authenticated\"><img data-src=\"//thumbs.phncdn.com/a.jpg\"></a></li>", finalURL: url, statusCode: 200)
        }, pornHubCookieHeader: { url in
            XCTAssertTrue(PornHubFeedParser.isAllowedHost(url.host))
            return "il=synthetic"
        })
        let page = try await signedIn.page(site: .pornHubSubscriptions, page: 1)
        XCTAssertEqual(page.items.map(\.siteID), [.pornHubSubscriptions])
        XCTAssertEqual(page.items.map(\.sourcePageURL.absoluteString), ["https://www.pornhub.com/view_video.php?viewkey=ph-auth"])
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ verify: ((Error) -> Void)? = nil) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error")
    } catch { verify?(error) }
}
