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

    func testFallsBackToCurrentMixDropMirrorAndAcceptsExtensionlessMediaURL() async throws {
        let requestedURL = URL(string: "https://mxdrop.to/e/abc123")!
        let mirrorURL = URL(string: "https://miiiixdrop.net/f/abc123")!
        let mediaURL = "https://edge.mxcontent.net/d/abc123/signed-delivery-token"
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                if url == requestedURL {
                    return HTTPPage(body: "<title>Unavailable mirror</title>", finalURL: url, statusCode: 200)
                }
                XCTAssertEqual(url, mirrorURL)
                return HTTPPage(
                    body: #"<script>MDCore.wurl = "\#(mediaURL)"</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        let resolution = try await resolver.resolve(url: requestedURL)

        XCTAssertEqual(resolution.qualities.first?.url.absoluteString, mediaURL)
        XCTAssertEqual(resolution.qualities.first?.headers["Referer"], mirrorURL.absoluteString)
        XCTAssertTrue(resolution.trace.contains { $0.contains("fallback mirror") })
    }

    func testDoesNotFetchMixDropMirrorWhenInitialPageResolves() async throws {
        let requestedURL = URL(string: "https://mixdrop.co/e/abc123")!
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                XCTAssertEqual(url, requestedURL, "A working provider page should not trigger a mirror fetch.")
                return HTTPPage(
                    body: #"<script>MDCore.wurl = "https://edge.mxcontent.net/v2/abc123.mp4"</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        let resolution = try await resolver.resolve(url: requestedURL)

        XCTAssertEqual(resolution.qualities.first?.url.absoluteString, "https://edge.mxcontent.net/v2/abc123.mp4")
        XCTAssertFalse(resolution.trace.contains { $0.contains("fallback mirror") })
    }

    func testRejectsPrivateAddressLiterals() {
        let blocked = [
            "http://0.0.0.0/",
            "http://[0:0:0:0:0:0:0:1]/",
            "http://[fd12:3456::1]/",
            "http://[fe80::1]/"
        ]

        for value in blocked {
            XCTAssertFalse(URLSafetyPolicy.isAllowed(URL(string: value)!), "\(value) must not be fetched by the agent.")
        }
    }

    func testRejectsUnsafeRedirectFinalURLFromProviderFetch() async throws {
        let resolver = StaticProviderResolver(
            fetch: { _, _ in
                HTTPPage(
                    body: #"<script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#,
                    finalURL: URL(string: "http://[fd00::1]/internal")!,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        do {
            _ = try await resolver.resolve(url: URL(string: "https://mixdrop.co/e/redirect")!)
            XCTFail("Expected an unsafe redirect destination to be rejected.")
        } catch ProviderResolverError.invalidURL {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectsNonMediaMixDropCDNAsset() async throws {
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                HTTPPage(
                    body: #"<script>MDCore.wurl = "https://edge.mxcontent.net/assets/player.js"</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        do {
            _ = try await resolver.resolve(url: URL(string: "https://mixdrop.co/e/abc123")!)
            XCTFail("Expected a non-media CDN asset to be rejected.")
        } catch ProviderResolverError.noMediaFound {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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

    func testResolvesStreamTapeHiddenGetVideoLinkAfterRedirect() async throws {
        let embedURL = URL(string: "https://streamtape.com/e/abc")!
        let getVideoURL = URL(string: "https://streamtape.com/get_video?id=abc&token=example")!
        let mediaURL = URL(string: "https://delivery.tapecontent.net/radosgw/abc/video.mp4")!
        let resolver = StaticProviderResolver(
            fetch: { url, headers in
                if url == embedURL {
                    return HTTPPage(
                        body: #"<span id="captchalink">https://streamtape.com/get_video?id=abc&token=example</span>"#,
                        finalURL: url,
                        statusCode: 200
                    )
                }
                XCTAssertEqual(url, getVideoURL)
                XCTAssertEqual(headers["Referer"], embedURL.absoluteString)
                return HTTPPage(body: "", finalURL: mediaURL, statusCode: 200)
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        let resolution = try await resolver.resolve(url: embedURL)

        XCTAssertEqual(resolution.qualities.first?.url, mediaURL)
        XCTAssertEqual(resolution.qualities.first?.headers["Referer"], embedURL.absoluteString)
    }
}
