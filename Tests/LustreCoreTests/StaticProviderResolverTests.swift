import LustreCore
import XCTest

final class StaticProviderResolverTests: XCTestCase {
    func testResolvesExactLiveMyDaddyEscapedSourceShape() async throws {
        let embedURL = URL(string: "https://mydaddy.cc/video/3f5db4343ed074bcca/")!
        let resolver = StaticProviderResolver(
            fetch: { url, headers in
                XCTAssertEqual(url, embedURL)
                XCTAssertEqual(headers["Referer"], "https://hqporner.com/")
                XCTAssertEqual(headers["User-Agent"], NetworkConstants.chromeUserAgent)
                return HTTPPage(
                    body: #"""
                    <video>
                      <source src=\"//s24.bigcdn.cc/pubs/6a61af23e66242.19596701/360.mp4\" title=\"360p\" type=\"video/mp4\" />
                      <source src=\"//s24.bigcdn.cc/pubs/6a61af23e66242.19596701/720.mp4\" title=\"720p HD\" type=\"video/mp4\" />
                      <source src=\"//s24.bigcdn.cc/pubs/6a61af23e66242.19596701/360.mp4\" title=\"360p\" type=\"video/mp4\" />
                      <source src=\"//s24.bigcdn.cc/pubs/6a61af23e66242.19596701/1080.mp4\" title=\"1080p Full HD\" type=\"video/mp4\" />
                    </video>
                    """#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        let resolution = try await resolver.resolve(url: embedURL)

        XCTAssertEqual(resolution.qualities.map(\.label), ["1080p Full HD", "720p HD", "360p"])
        XCTAssertEqual(resolution.qualities.map(\.url.absoluteString), [
            "https://s24.bigcdn.cc/pubs/6a61af23e66242.19596701/1080.mp4",
            "https://s24.bigcdn.cc/pubs/6a61af23e66242.19596701/720.mp4",
            "https://s24.bigcdn.cc/pubs/6a61af23e66242.19596701/360.mp4"
        ])
        XCTAssertTrue(resolution.qualities.allSatisfy {
            $0.headers["Referer"] == "https://hqporner.com/"
                && $0.headers["User-Agent"] == NetworkConstants.chromeUserAgent
        })
    }

    func testResolvesMyDaddySourceTagsWithDeterministicQualitiesAndHeaders() async throws {
        let embedURL = URL(string: "https://embed.mydaddy.cc/video/working")!
        let resolver = StaticProviderResolver(
            fetch: { url, headers in
                XCTAssertEqual(url, embedURL)
                XCTAssertEqual(headers["User-Agent"], NetworkConstants.chromeUserAgent)
                XCTAssertEqual(headers["Referer"], "https://hqporner.com/")
                return HTTPPage(
                    body: #"""
                    <html><head><title>Fixture video</title></head><body><video>
                      <source src="//cdn.example.com/video-720.mp4" title="720p">
                      <source label="1080p" src="/media/video-1080.mp4">
                      <source src="https://cdn.example.com/video-720.mp4" label="720p duplicate">
                      <source src="https://cdn.example.com/player.js" label="2160p">
                      <source src="https://cdn.example.com/poster.jpg" label="480p">
                      <source src="https://cdn.example.com/watch" label="360p">
                    </video></body></html>
                    """#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        let resolution = try await resolver.resolve(url: embedURL)

        XCTAssertEqual(resolution.sourcePageURL, embedURL)
        XCTAssertEqual(resolution.provider, .myDaddy)
        XCTAssertEqual(resolution.title, "Fixture video")
        XCTAssertEqual(resolution.qualities.map(\.label), ["1080p", "720p"])
        XCTAssertEqual(resolution.qualities.map(\.url.absoluteString), [
            "https://embed.mydaddy.cc/media/video-1080.mp4",
            "https://cdn.example.com/video-720.mp4"
        ])
        XCTAssertTrue(resolution.qualities.allSatisfy {
            $0.headers["Referer"] == "https://hqporner.com/"
                && $0.headers["User-Agent"] == NetworkConstants.chromeUserAgent
                && $0.resolutionMethod == "Static mydaddy source resolver"
        })
        XCTAssertTrue(resolution.trace.contains { $0.contains("2 unique media") })
    }

    func testMyDaddyBlockedPageReturnsNoMediaFound() async throws {
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                HTTPPage(
                    body: "<html><body>This domain has been blocked.</body></html>",
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        do {
            _ = try await resolver.resolve(url: URL(string: "https://mydaddy.cc/video/3f5db4343ed074bcca/")!)
            XCTFail("Expected a blocked page with no source tags to return noMediaFound.")
        } catch ProviderResolverError.noMediaFound {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDoesNotTrustMyDaddyLookalikeHost() async throws {
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                XCTFail("Lookalike host must not be fetched.")
                return HTTPPage(body: "", finalURL: url, statusCode: 200)
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        do {
            _ = try await resolver.resolve(url: URL(string: "https://mydaddy.cc.attacker.example/video/abc")!)
            XCTFail("Expected the lookalike host to remain unsupported.")
        } catch ProviderResolverError.unsupportedProvider {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

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
