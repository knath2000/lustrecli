import Foundation
import LustreCore
import XCTest

final class HQPornerResolverTests: XCTestCase {
    func testRecognizesOnlyCanonicalHTTPSVideoPages() {
        XCTAssertTrue(StaticProviderResolver.isHQPornerSourceURL(URL(string: "https://hqporner.com/hdporn/123-slug")!))
        XCTAssertTrue(StaticProviderResolver.isHQPornerSourceURL(URL(string: "https://www.hqporner.com/hdporn/123-slug")!))
        for value in [
            "http://hqporner.com/hdporn/123-slug",
            "https://hqporner.com.attacker.example/hdporn/123-slug",
            "https://hqporner.com/",
            "https://hqporner.com/hdporn/not-numeric",
            "https://hqporner.com/search/123"
        ] {
            XCTAssertFalse(StaticProviderResolver.isHQPornerSourceURL(URL(string: value)!))
        }
    }

    func testDelegatesEscapedTrustedIframeAndPreservesDurableSourceAndMetadata() async throws {
        let source = URL(string: "https://hqporner.com/hdporn/123-fixture")!
        let embed = URL(string: "https://mydaddy.cc/video/abc/")!
        let resolver = StaticProviderResolver(fetch: { url, headers in
            XCTAssertEqual(headers["User-Agent"], NetworkConstants.chromeUserAgent)
            XCTAssertEqual(headers["Referer"], "https://hqporner.com/")
            if url == source {
                return HTTPPage(
                    body: #"<title>Fixture title | HQPorner</title><meta property=\"og:image\" content=\"//img.hqporner.com/poster.jpg\"><iframe src=\"//mydaddy.cc/video/abc/\"></iframe>"#,
                    finalURL: source,
                    statusCode: 200
                )
            }
            XCTAssertEqual(url, embed)
            return HTTPPage(
                body: #"<title>Embed fallback</title><source src=\"//cdn.example/720.mp4\" title=\"720p\"><source src=\"//cdn.example/1080.mp4\" title=\"1080p\">"#,
                finalURL: embed,
                statusCode: 200
            )
        }, randomSuffix: { "unused" }, nowMilliseconds: { "0" })

        let resolution = try await resolver.resolve(url: source)

        XCTAssertEqual(resolution.provider, .hqPorner)
        XCTAssertEqual(resolution.sourcePageURL, source)
        XCTAssertEqual(resolution.title, "Fixture title")
        XCTAssertEqual(resolution.thumbnailURL?.absoluteString, "https://img.hqporner.com/poster.jpg")
        XCTAssertEqual(resolution.qualities.map(\.label), ["1080p", "720p"])
        XCTAssertTrue(resolution.qualities.allSatisfy {
            $0.headers["Referer"] == "https://hqporner.com/"
                && $0.headers["User-Agent"] == NetworkConstants.chromeUserAgent
                && $0.mediaKind == .direct
        })
        XCTAssertTrue(resolution.trace.contains { $0.contains("HQPorner") && $0.contains("mydaddy") })
        XCTAssertFalse(resolution.trace.joined().contains("cdn.example"))
    }

    func testRejectsUntrustedIframeAndUnsafeRedirect() async {
        let source = URL(string: "https://hqporner.com/hdporn/123-fixture")!
        for page in [
            HTTPPage(body: #"<iframe src="https://mydaddy.cc.attacker.example/video/bad"></iframe>"#, finalURL: source, statusCode: 200),
            HTTPPage(body: #"<iframe src="https://mydaddy.cc/video/good"></iframe>"#, finalURL: URL(string: "https://attacker.example/")!, statusCode: 200)
        ] {
            let resolver = StaticProviderResolver(fetch: { _, _ in page }, randomSuffix: { "unused" }, nowMilliseconds: { "0" })
            await XCTAssertThrowsErrorAsync(try await resolver.resolve(url: source))
        }
    }

    func testTriesTrustedCandidatesInSourceOrderUntilOneResolves() async throws {
        actor Calls {
            var values: [URL] = []
            func append(_ url: URL) { values.append(url) }
            func snapshot() -> [URL] { values }
        }
        let calls = Calls()
        let source = URL(string: "https://hqporner.com/hdporn/123-fixture")!
        let first = URL(string: "https://mydaddy.cc/video/first")!
        let second = URL(string: "https://embed.mydaddy.cc/video/second")!
        let resolver = StaticProviderResolver(fetch: { url, _ in
            await calls.append(url)
            if url == source {
                return HTTPPage(body: #"<iframe src="//mydaddy.cc/video/first"></iframe><iframe src="https:\/\/embed.mydaddy.cc\/video\/second"></iframe><iframe src="//mydaddy.cc/video/first"></iframe>"#, finalURL: source, statusCode: 200)
            }
            if url == first { return HTTPPage(body: "<html>No sources</html>", finalURL: first, statusCode: 200) }
            return HTTPPage(body: #"<title>Working embed</title><source src="//cdn.example/video.mp4" label="Video">"#, finalURL: second, statusCode: 200)
        }, randomSuffix: { "unused" }, nowMilliseconds: { "0" })

        let resolution = try await resolver.resolve(url: source)

        let requestedURLs = await calls.snapshot()
        XCTAssertEqual(requestedURLs, [source, first, second])
        XCTAssertEqual(resolution.title, "Working embed")
        XCTAssertEqual(resolution.sourcePageURL, source)
        XCTAssertEqual(resolution.qualities.first?.url.absoluteString, "https://cdn.example/video.mp4")
    }

    func testAllTrustedCandidatesFailOnlyAfterEveryAttempt() async {
        actor Count {
            var embeds = 0
            func increment() { embeds += 1 }
            func value() -> Int { embeds }
        }
        let count = Count()
        let source = URL(string: "https://hqporner.com/hdporn/123-fixture")!
        let resolver = StaticProviderResolver(fetch: { url, _ in
            if url == source {
                return HTTPPage(body: #"<iframe src="//mydaddy.cc/video/one"></iframe><iframe src="//mydaddy.cc/video/two"></iframe>"#, finalURL: source, statusCode: 200)
            }
            await count.increment()
            throw ProviderResolverError.network("fixture failure")
        }, randomSuffix: { "unused" }, nowMilliseconds: { "0" })

        await XCTAssertThrowsErrorAsync(try await resolver.resolve(url: source))
        let embedCount = await count.value()
        XCTAssertEqual(embedCount, 2)
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
