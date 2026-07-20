import LustreCore
import XCTest

final class StaticProviderResolverTests: XCTestCase {
    func testResolvesPlaymogoPassURLWithRequiredHeaders() async throws {
        let resolver = StaticProviderResolver(
            fetch: { url, headers in
                if url.path.contains("pass_md5") {
                    XCTAssertEqual(headers["Referer"], "https://playmogo.com/e/abc")
                    return HTTPPage(body: "https://edge.cloudatacdn.com/media/~", finalURL: url, statusCode: 200)
                }
                return HTTPPage(
                    body: #"<title>Example</title><script>$.get('/pass_md5/abc', function(a) { return a + '?token=token-value&expiry=' + Date.now() })</script>"#,
                    finalURL: URL(string: "https://playmogo.com/e/abc")!,
                    statusCode: 200
                )
            },
            randomSuffix: { "abcdefghij" },
            nowMilliseconds: { "1700000000000" }
        )

        let resolution = try await resolver.resolve(url: URL(string: "https://vide0.net/e/abc")!)

        XCTAssertEqual(resolution.provider, .doodStream)
        XCTAssertEqual(resolution.title, "Example")
        XCTAssertEqual(resolution.qualities.first?.url.absoluteString, "https://edge.cloudatacdn.com/media/~abcdefghij?token=token-value&expiry=1700000000000")
        XCTAssertEqual(resolution.qualities.first?.headers["Referer"], "https://playmogo.com/e/abc")
        XCTAssertEqual(resolution.qualities.first?.resolutionMethod, "Static Playmogo resolver")
    }

    func testResolvesMixDropStaticMediaConfiguration() async throws {
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                HTTPPage(
                    body: #"<title>Mix</title><script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        let resolution = try await resolver.resolve(url: URL(string: "https://mixdrop.co/e/xyz")!)

        XCTAssertEqual(resolution.provider, .mixDrop)
        XCTAssertEqual(resolution.qualities.first?.url.absoluteString, "https://cdn.mxcontent.net/video.mp4")
        XCTAssertEqual(resolution.qualities.first?.headers["Referer"], "https://mixdrop.co/e/xyz")
    }

    func testClassifiesCloudflareChallengeForVerificationBridge() async throws {
        let resolver = StaticProviderResolver(
            fetch: { url, _ in HTTPPage(body: "<html>cf-mitigated: challenge</html>", finalURL: url, statusCode: 403) },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        do {
            _ = try await resolver.resolve(url: URL(string: "https://playmogo.com/e/abc")!)
            XCTFail("Expected a Cloudflare verification result")
        } catch ProviderResolverError.cloudflareChallenge {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResolvesStreamTapeStaticMediaConfiguration() async throws {
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                HTTPPage(
                    body: #"<title>Tape</title><script>sources:[{file: "https://streamta.pe/get_video?id=abc"}]</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        let resolution = try await resolver.resolve(url: URL(string: "https://streamtape.com/e/xyz")!)

        XCTAssertEqual(resolution.provider, .streamTape)
        XCTAssertEqual(resolution.qualities.first?.url.absoluteString, "https://streamta.pe/get_video?id=abc")
        XCTAssertEqual(resolution.qualities.first?.resolutionMethod, "Static StreamTape resolver")
    }
}
