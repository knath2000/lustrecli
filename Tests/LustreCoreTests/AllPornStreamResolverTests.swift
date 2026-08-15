import LustreCore
import XCTest

final class AllPornStreamResolverTests: XCTestCase {
    func testRejectsCloudflareChallengeOnPostPageBeforeParsingMetadata() async throws {
        let postURL = URL(string: "https://allpornstream.com/post/challenged")!
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                HTTPPage(body: "<html>cf-mitigated: challenge</html>", finalURL: url, statusCode: 403)
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        do {
            _ = try await AllPornStreamResolver(fetch: resolver.pageFetch, providerResolver: resolver).resolve(postURL: postURL)
            XCTFail("Expected the post-page challenge to require verification.")
        } catch ProviderResolverError.cloudflareChallenge {
        }
    }

    func testKeepsMyDaddySuccessWhenAnotherConcurrentCandidateFails() async throws {
        let postURL = URL(string: "https://allpornstream.com/post/partial-mydaddy")!
        let mixDropURL = URL(string: "https://mixdrop.co/e/broken")!
        let myDaddyURL = URL(string: "https://mydaddy.cc/video/working/")!
        let fetchLog = CandidateFetchLog()
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                if url == postURL {
                    return HTTPPage(
                        body: #"""
                        {"video_urls":[
                          {"hosting_provider":"MIXDROP","file_code":"broken","iframe":"https://mixdrop.co/e/broken"},
                          {"hosting_provider":"UNKNOWN","file_code":"working","iframe":"https://mydaddy.cc/video/working/"}
                        ]}
                        """#,
                        finalURL: url,
                        statusCode: 200
                    )
                }
                await fetchLog.record(url)
                if url != myDaddyURL {
                    try await Task.sleep(for: .milliseconds(20))
                    return HTTPPage(body: "<html>No media here</html>", finalURL: url, statusCode: 200)
                }
                XCTAssertEqual(url, myDaddyURL)
                return HTTPPage(
                    body: #"<source src=\"//media.example.com/1080.mp4\" title=\"1080p Full HD\" type=\"video/mp4\" />"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        let result = try await AllPornStreamResolver(fetch: resolver.pageFetch, providerResolver: resolver).resolve(postURL: postURL)

        XCTAssertEqual(result.attempts.map(\.providerName), ["MIXDROP", "UNKNOWN"])
        XCTAssertEqual(result.attempts.map(\.outcome), [.failed, .resolved])
        XCTAssertEqual(result.resolution.qualities.map(\.label), ["UNKNOWN · 1080p Full HD"])
        XCTAssertEqual(result.resolution.qualities.first?.url.absoluteString, "https://media.example.com/1080.mp4")
        let fetchedURLs = await fetchLog.urls()
        XCTAssertTrue(fetchedURLs.contains(mixDropURL))
        XCTAssertTrue(fetchedURLs.contains(myDaddyURL))
    }

    func testRoutesUnknownMyDaddyCandidateByActualSourceHost() async throws {
        let postURL = URL(string: "https://allpornstream.com/post/mydaddy")!
        let embedURL = URL(string: "https://mydaddy.cc/video/working/")!
        let resolver = StaticProviderResolver(
            fetch: { url, headers in
                if url == postURL {
                    return HTTPPage(
                        body: #"{"video_urls":[{"hosting_provider":"UNKNOWN","file_code":"working","iframe":"https://mydaddy.cc/video/working/"}]}"#,
                        finalURL: url,
                        statusCode: 200
                    )
                }
                XCTAssertEqual(url, embedURL)
                XCTAssertEqual(headers["Referer"], "https://hqporner.com/")
                return HTTPPage(
                    body: #"<video><source src="https://media.example.com/working.mp4" title="720p"></video>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        let result = try await AllPornStreamResolver(fetch: resolver.pageFetch, providerResolver: resolver).resolve(postURL: postURL)

        XCTAssertEqual(result.attempts.first?.providerName, "UNKNOWN")
        XCTAssertEqual(result.attempts.first?.outcome, .resolved)
        XCTAssertEqual(result.attempts.first?.resolutionMethod, "Static mydaddy source resolver")
        XCTAssertNotEqual(result.attempts.first?.reason, "No static resolver is installed for this hosting_provider.")
        XCTAssertEqual(result.resolution.qualities.first?.label, "UNKNOWN · 720p")
        XCTAssertEqual(result.resolution.qualities.first?.url.absoluteString, "https://media.example.com/working.mp4")
    }

    func testDoesNotRouteUnknownCandidateFromUnrelatedHostToMyDaddy() async throws {
        let postURL = URL(string: "https://allpornstream.com/post/unknown")!
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                XCTAssertEqual(url, postURL)
                return HTTPPage(
                    body: #"{"video_urls":[{"hosting_provider":"UNKNOWN","iframe":"https://notmydaddy.cc/video/working/"}]}"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        let result = try await AllPornStreamResolver(fetch: resolver.pageFetch, providerResolver: resolver).resolve(postURL: postURL)

        XCTAssertEqual(result.attempts.first?.outcome, .failed)
        XCTAssertEqual(result.attempts.first?.reason, "No static resolver is installed for this hosting_provider.")
        XCTAssertTrue(result.resolution.qualities.isEmpty)
    }

    func testParsesNextFlightMetadataPairsEmbedsAndPreservesProviderOrder() {
        let postURL = URL(string: "https://allpornstream.com/post/example")!
        let html = #"""
        <script>self.__next_f.push([1,"1:{\"title\":\"Flight title\",\"thumbnail\":\"/cover.jpg\",\"video_urls\":[{\"hosting_provider\":\"DOODSTREAM\",\"file_code\":\"dood-1\",\"link\":\"https://alias.example/d/dood-1\"},{\"hosting_provider\":\"DOODSTREAM\",\"file_code\":\"dood-1\",\"iframe\":\"https://alias.example/e/dood-1\"},{\"hosting_provider\":\"MIXDROP\",\"file_code\":\"mix-1\",\"iframe\":\"https://mixdrop.co/e/mix-1\"}]}"])</script>
        """#

        let metadata = AllPornStreamResolver.parseMetadata(from: html, relativeTo: postURL)

        XCTAssertEqual(metadata.title, "Flight title")
        XCTAssertEqual(metadata.thumbnailURL?.absoluteString, "https://allpornstream.com/cover.jpg")
        XCTAssertEqual(metadata.candidates.map(\.providerName), ["DOODSTREAM", "MIXDROP"])
        XCTAssertEqual(metadata.candidates.map(\.fileCode), ["dood-1", "mix-1"])
        XCTAssertEqual(metadata.candidates.first?.sourceURL?.absoluteString, "https://alias.example/e/dood-1")
        XCTAssertEqual(metadata.candidates.first?.trustedProvider, .doodStream)
    }

    func testParsesInlineMetadataAndReportsMalformedRecords() {
        let postURL = URL(string: "https://allpornstream.com/post/example")!
        let html = #"""
        <script>
          const video_urls = [
            {"hosting_provider":"STREAMTAPE","file_code":"tape-1","link":"https://streamtape.com/e/tape-1"},
            {"hosting_provider":"VIDARA","file_code":"broken","iframe":"not a URL"}
          ];
        </script>
        """#

        let metadata = AllPornStreamResolver.parseMetadata(from: html, relativeTo: postURL)

        XCTAssertEqual(metadata.candidates.map(\.providerName), ["STREAMTAPE", "VIDARA"])
        XCTAssertEqual(metadata.candidates.first?.sourceURL?.absoluteString, "https://streamtape.com/e/tape-1")
        XCTAssertNil(metadata.candidates.last?.sourceURL)
        XCTAssertNil(metadata.candidates.last?.trustedProvider)
    }

    func testReportsNoCandidatesWhenVideoURLsMetadataIsMissing() {
        let metadata = AllPornStreamResolver.parseMetadata(
            from: #"<script>self.__next_f.push([1,"1:{\"title\":\"No sources\"}"])</script>"#,
            relativeTo: URL(string: "https://allpornstream.com/post/empty")!
        )

        XCTAssertEqual(metadata.title, "No sources")
        XCTAssertTrue(metadata.candidates.isEmpty)
    }

    func testParsesProviderTupleLinksAndEmbedURLRecordsFromPostMetadata() {
        let html = #"""
        <script id="__NEXT_DATA__" type="application/json">{
          "title":"Provider tuple fixture",
          "image_details":["https://images.example.com/cover.webp"],
          "video_urls":{
            "link":[
              ["STREAMTAPE","https://streamtape.com/v/stream-code"],
              ["MIIIIIXDROP.NET","https://miiiiixdrop.net/f/mix-code"],
              ["DOODSTREAM","https://doodstream.com/d/dood-code"]
            ],
            "direct":[],
            "iframe":[
              {"hosting_provider":"STREAMTAPE","file_code":"stream-code","embed_url":"https://streamtape.com/e/stream-code"},
              {"hosting_provider":"MIIIIIXDROP.NET","file_code":null,"embed_url":"https://miiiiixdrop.net/e/mix-code"},
              {"hosting_provider":"DOODSTREAM","file_code":"dood-code","embed_url":"https://doodstream.com/e/dood-code"}
            ]
          }
        }</script>
        """#

        let metadata = AllPornStreamResolver.parseMetadata(
            from: html,
            relativeTo: URL(string: "https://allpornstream.com/post/live-schema")!
        )

        XCTAssertEqual(metadata.thumbnailURL?.absoluteString, "https://images.example.com/cover.webp")
        XCTAssertEqual(metadata.candidates.map(\.providerName), ["STREAMTAPE", "MIIIIIXDROP.NET", "DOODSTREAM"])
        XCTAssertEqual(metadata.candidates.map(\.sourceURL?.absoluteString), [
            "https://streamtape.com/e/stream-code",
            "https://miiiiixdrop.net/e/mix-code",
            "https://doodstream.com/e/dood-code"
        ])
        XCTAssertEqual(metadata.candidates.map(\.trustedProvider), [.streamTape, .mixDrop, .doodStream])
    }

    func testTrustedDoodProviderUsesPlaymogoResolverForUnknownHost() async throws {
        let postURL = URL(string: "https://allpornstream.com/post/dood")!
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                if url == postURL {
                    return HTTPPage(
                        body: #"{"video_urls":[{"hosting_provider":"DOODSTREAM","file_code":"abc","iframe":"https://trusted-alias.example/e/abc"}]}"#,
                        finalURL: url,
                        statusCode: 200
                    )
                }
                XCTAssertEqual(url.host, "playmogo.com")
                if url.path.contains("pass_md5") {
                    return HTTPPage(body: "https://edge.cloudatacdn.com/media/~", finalURL: url, statusCode: 200)
                }
                return HTTPPage(
                    body: #"<script>$.get('/pass_md5/abc', function(a) { return a + '?token=token-value&expiry=' + Date.now() })</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "abcdefghij" },
            nowMilliseconds: { "1700000000000" }
        )

        let result = try await AllPornStreamResolver(fetch: resolver.pageFetch, providerResolver: resolver).resolve(postURL: postURL)

        XCTAssertEqual(result.attempts.first?.outcome, .resolved)
        XCTAssertEqual(result.attempts.first?.resolutionMethod, "Static Playmogo resolver")
        XCTAssertEqual(result.resolution.qualities.first?.label, "DOODSTREAM · Video")
        XCTAssertEqual(result.resolution.qualities.first?.url.absoluteString, "https://edge.cloudatacdn.com/media/~abcdefghij?token=token-value&expiry=1700000000000")
    }

    func testLimitsProviderResolutionToThreeConcurrentAttempts() async throws {
        let postURL = URL(string: "https://allpornstream.com/post/concurrency")!
        let tracker = ConcurrentFetchTracker()
        let providerRecords = (1...4).map {
            #"{"hosting_provider":"MIXDROP","file_code":"mix-\#($0)","iframe":"https://provider-\#($0).example/e/mix-\#($0)"}"#
        }.joined(separator: ",")
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                if url == postURL {
                    return HTTPPage(body: "{\"video_urls\":[\(providerRecords)]}", finalURL: url, statusCode: 200)
                }
                await tracker.providerStarted()
                try await Task.sleep(for: .milliseconds(25))
                await tracker.providerFinished()
                return HTTPPage(
                    body: #"<script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        let result = try await AllPornStreamResolver(fetch: resolver.pageFetch, providerResolver: resolver).resolve(postURL: postURL)

        XCTAssertEqual(result.resolution.qualities.count, 4)
        let maximumInFlight = await tracker.maximumInFlight()
        XCTAssertEqual(maximumInFlight, 3)
    }

    func testTimesOutProviderAttemptAndKeepsDiagnostic() async throws {
        let postURL = URL(string: "https://allpornstream.com/post/timeout")!
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                if url == postURL {
                    return HTTPPage(
                        body: #"{"video_urls":[{"hosting_provider":"MIXDROP","file_code":"slow","iframe":"https://slow.example/e/slow"}]}"#,
                        finalURL: url,
                        statusCode: 200
                    )
                }
                try await Task.sleep(for: .milliseconds(100))
                return HTTPPage(body: "", finalURL: url, statusCode: 200)
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )

        let result = try await AllPornStreamResolver(
            fetch: resolver.pageFetch,
            providerResolver: resolver,
            providerTimeout: .milliseconds(5)
        ).resolve(postURL: postURL)

        XCTAssertEqual(result.attempts.first?.outcome, .timedOut)
        XCTAssertTrue(result.resolution.trace.contains { $0.contains("timed out") })
    }

}

private actor ConcurrentFetchTracker {
    private var inFlight = 0
    private var maximum = 0

    func providerStarted() {
        inFlight += 1
        maximum = max(maximum, inFlight)
    }

    func providerFinished() {
        inFlight -= 1
    }

    func maximumInFlight() -> Int {
        maximum
    }
}

private actor CandidateFetchLog {
    private var fetchedURLs: [URL] = []

    func record(_ url: URL) {
        fetchedURLs.append(url)
    }

    func urls() -> [URL] {
        fetchedURLs
    }
}
