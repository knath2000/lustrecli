import XCTest
@testable import LustreCore

final class HLSProviderResolverTests: XCTestCase {
    func testVidaraPostsJSONAndSortsRelativeVariants() async throws {
        actor Capture {
            var requests: [ProviderHTTPRequest] = []
            func add(_ request: ProviderHTTPRequest) { requests.append(request) }
        }
        let capture = Capture()
        let resolver = StaticProviderResolver(requestFetch: { request in
            await capture.add(request)
            if request.url.path == "/api/stream" {
                return HTTPPage(body: #"{"streaming_url":"https://media.example/path/master.m3u8","title":"Fixture","thumbnail":"https://images.example/a.jpg"}"#, finalURL: request.url, statusCode: 200)
            }
            return HTTPPage(body: """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1280x720
            720/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2,RESOLUTION=1920x1080
            /1080/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=3,RESOLUTION=1920x1080
            /1080/index.m3u8
            """, finalURL: request.url, statusCode: 200)
        })
        let result = try await resolver.resolve(url: URL(string: "https://vidara.so/v/safe_code")!)
        let requests = await capture.requests
        XCTAssertEqual(result.provider, .vidara)
        XCTAssertEqual(result.qualities.map(\.label), ["1080p", "720p"])
        XCTAssertEqual(result.qualities.map(\.mediaKind), [.hls, .hls])
        XCTAssertEqual(requests.first?.method, "POST")
        XCTAssertEqual(requests.first?.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(requests.first?.body)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["device": "web", "filecode": "safe_code"])
        XCTAssertEqual(requests.last?.headers["Referer"], "https://vidara.so/")
    }

    func testVidaraRejectsLookalikesUnsafeStreamsAndMalformedPaths() async {
        let resolver = StaticProviderResolver(requestFetch: { request in
            HTTPPage(body: #"{"streaming_url":"http://media.example/master.m3u8"}"#, finalURL: request.url, statusCode: 200)
        })
        await assertThrows { _ = try await resolver.resolve(url: URL(string: "https://vidara.so.evil.example/v/code")!) }
        await assertThrows { _ = try await resolver.resolve(url: URL(string: "https://vidara.so/v/code")!) }
        await assertThrows { _ = try await resolver.resolve(url: URL(string: "https://vidara.so/watch/code")!) }
    }

    func testLuluPackedPlayerSupportsEscapedRealArgumentShape() async throws {
        let dictionary = (0..<40).map { index in
            switch index {
            case 36: "jwplayer"
            case 37: "fixture"
            case 38: "setup"
            case 39: "file"
            default: ""
            }
        }.joined(separator: "|")
        let embedBody = #"""
        <script>
        eval(function(p,a,c,k,e,d){e=function(c){return c.toString(a)};if(!''.replace(/^/,String)){while(c--)d[e(c)]=k[c]||e(c);k=[function(e){return d[e]}];e=function(){return'\\w+'};c=1};while(c--)if(k[c])p=p.replace(new RegExp('\\b'+e(c)+'\\b','g'),k[c]);return p}
        ("A(\"B\").C({D:\"https:\/\/media.example\/master.m3u8\",label:\"fixture, value\"});",62,40,"\#(dictionary)".split('|'),0,{}))
        </script>
        """#
        let resolver = StaticProviderResolver(requestFetch: { request in
            switch request.url.host {
            case "luluvid.com": HTTPPage(body: "<title>Lulu Fixture</title>", finalURL: request.url, statusCode: 200)
            case "luluvdo.com": HTTPPage(body: embedBody, finalURL: request.url, statusCode: 200)
            default: HTTPPage(body: "#EXTM3U", finalURL: request.url, statusCode: 200)
            }
        })

        let result = try await resolver.resolve(url: URL(string: "https://luluvdo.com/e/fixture")!)

        XCTAssertEqual(result.qualities.first?.url.absoluteString, "https://media.example/master.m3u8")
    }

    func testLuluPlainAndPackedPlayersPreserveEmbedContext() async throws {
        for embedBody in [
            #"file: "https://media.example/master.m3u8""#,
            #"<script>eval(function(p,a,c,k,e,d){}('0("1").2({3:"https://media.example/master.m3u8"});',36,4,'jwplayer|x|setup|file'.split('|')))</script>"#
        ] {
            let resolver = StaticProviderResolver(requestFetch: { request in
                switch request.url.host {
                case "luluvid.com": HTTPPage(body: "<title>Lulu Fixture</title>", finalURL: request.url, statusCode: 200)
                case "luluvdo.com": HTTPPage(body: embedBody, finalURL: request.url, statusCode: 200)
                default: HTTPPage(body: "#EXTM3U", finalURL: request.url, statusCode: 200)
                }
            })
            let result = try await resolver.resolve(url: URL(string: "https://lulustream.com/d/abc_123")!)
            XCTAssertEqual(result.provider, .luluStream)
            XCTAssertEqual(result.sourcePageURL.absoluteString, "https://luluvdo.com/e/abc_123")
            XCTAssertEqual(result.qualities.first?.headers["Referer"], "https://luluvdo.com/e/abc_123")
            XCTAssertEqual(result.qualities.first?.mediaKind, .hls)
        }
    }

    func testOldResolvedQualityDefaultsToDirect() throws {
        let data = Data(#"{"label":"Video","url":"https://media.example/video.mp4","headers":{},"resolutionMethod":"legacy"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ResolvedQuality.self, from: data).mediaKind, .direct)
    }

    private func assertThrows(_ expression: () async throws -> Void) async {
        do {
            try await expression()
            XCTFail("Expected error")
        } catch {}
    }
}
