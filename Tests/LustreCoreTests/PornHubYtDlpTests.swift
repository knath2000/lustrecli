import XCTest
@testable import LustreAgent
@testable import LustreCore

final class PornHubYtDlpTests: XCTestCase {
    let source = URL(string: "https://www.pornhub.com/view_video.php?viewkey=ph-safe_1")!

    func testCanonicalSourceRecognitionRejectsLookalikesPlaylistsAndMalformedQueries() {
        XCTAssertEqual(PornHubURL.canonical(source), source)
        for raw in [
            "http://www.pornhub.com/view_video.php?viewkey=ph-safe",
            "https://pornhub.com.evil.test/view_video.php?viewkey=ph-safe",
            "https://www.pornhub.com/playlist/1",
            "https://www.pornhub.com/view_video.php?viewkey=bad%0Akey",
            "https://www.pornhub.com/view_video.php?viewkey=ph-safe&playlist=1"
        ] {
            XCTAssertNil(PornHubURL.canonical(URL(string: raw)!))
        }
    }

    func testMetadataArgumentsAndExecutableAllowlist() throws {
        XCTAssertTrue(PornHubYtDlp.executableIsAllowed(URL(fileURLWithPath: "/usr/local/bin/yt-dlp")))
        XCTAssertFalse(PornHubYtDlp.executableIsAllowed(URL(fileURLWithPath: "/tmp/yt-dlp")))
        XCTAssertEqual(try PornHubYtDlp.metadataArguments(source: source), [
            "--no-playlist", "--dump-single-json", "--no-download", "--no-warnings", "--socket-timeout", "20",
            source.absoluteString
        ])
    }

    func testJSONParsingRanksCompleteFormatsAndUsesDurableSourceForMaterialization() throws {
        let json = """
        {"title":"Public title","thumbnail":"https://thumbs.phncdn.com/a.jpg","http_headers":{"Referer":"https://www.pornhub.com/"},
         "formats":[
           {"format_id":"direct1080","height":1080,"ext":"mp4","protocol":"https","url":"https://cdn.example/complete.mp4"},
           {"format_id":"h720","height":720,"vcodec":"avc1","acodec":"mp4a","ext":"mp4","protocol":"https","url":"https://cdn.example/a.mp4"},
          {"format_id":"h720","height":720,"vcodec":"avc1","acodec":"mp4a","ext":"mp4","url":"https://cdn.example/duplicate.mp4"},
          {"format_id":"h480","height":480,"vcodec":"avc1","acodec":"mp4a","ext":"mp4","url":"https://cdn.example/b.mp4","http_headers":{"X-Test":"ok"}}
         ]}
        """
        let resolution = try PornHubYtDlp.parseMetadata(Data(json.utf8), source: source)
        XCTAssertEqual(resolution.provider, .pornHub)
        XCTAssertEqual(resolution.title, "Public title")
        XCTAssertEqual(resolution.qualities.map(\.label), ["1080p MP4", "720p MP4", "480p MP4"])
        XCTAssertEqual(resolution.qualities.map(\.url), [source, source, source])
        XCTAssertEqual(resolution.qualities.map(\.formatSelector), ["direct1080", "h720", "h480"])
        XCTAssertEqual(resolution.qualities[2].headers["X-Test"], "ok")
    }

    func testExplicitVideoOnlyFormatPairsWithSafeAudioSelector() throws {
        let json = """
        {"formats":[
          {"format_id":"a1","vcodec":"none","acodec":"mp4a","abr":128,"url":"https://cdn.example/audio.m4a"},
          {"format_id":"v1080","height":1080,"vcodec":"avc1","acodec":"none","ext":"mp4","url":"https://cdn.example/video.mp4"}
        ]}
        """

        let resolution = try PornHubYtDlp.parseMetadata(Data(json.utf8), source: source)

        XCTAssertEqual(resolution.qualities.map(\.formatSelector), ["v1080+a1"])
    }

    func testRejectsUnsafeHeadersMalformedAndOversizedJSON() {
        let badHeader = #"{"formats":[{"format_id":"1","height":720,"vcodec":"x","acodec":"a","url":"https://cdn.example/x.mp4","http_headers":{"X":"bad\r\nInjected: yes"}}]}"#
        XCTAssertThrowsError(try PornHubYtDlp.parseMetadata(Data(badHeader.utf8), source: source))
        XCTAssertThrowsError(try PornHubYtDlp.parseMetadata(Data("{}".utf8), source: source))
        XCTAssertThrowsError(try PornHubYtDlp.parseMetadata(Data(repeating: 0x20, count: PornHubYtDlp.maximumMetadataBytes + 1), source: source))
    }

    func testMaterializationArgumentsConstrainFormatAndOutputDirectory() throws {
        let dir = URL(fileURLWithPath: "/tmp/stage")
        let args = try PornHubYtDlp.materializationArguments(source: source, formatSelector: "h720", directory: dir)
        XCTAssertEqual(args.suffix(2), ["\(dir.path)/lustre-pornhub.%(ext)s", source.absoluteString])
        XCTAssertTrue(args.contains("--restrict-filenames"))
        XCTAssertTrue(args.contains("--merge-output-format"))
        XCTAssertFalse(args.contains("--cookies-from-browser"))
        XCTAssertThrowsError(try PornHubYtDlp.materializationArguments(source: source, formatSelector: "best;rm", directory: dir))
    }

    func testFailureClassificationOnlyInvalidatesClearSessionFailures() async throws {
        XCTAssertEqual(PornHubYtDlp.classifiedFailure(Data("ERROR: Login required to access this video".utf8)), .sessionExpired)
        XCTAssertEqual(PornHubYtDlp.classifiedFailure(Data("ERROR: This is a Premium video".utf8)), .authenticationUnsupported)
        XCTAssertEqual(PornHubYtDlp.classifiedFailure(Data("ERROR: Video unavailable in your region".utf8)), .temporarilyUnavailable)
        XCTAssertEqual(PornHubYtDlp.classifiedFailure(Data("ERROR: network timeout".utf8)), .processFailed)

        let store = AuthCookieStore(cookies: [PornHubCookieRecord(name: "il", value: "synthetic-session-value", domain: ".pornhub.com", path: "/", expiresAt: nil, secure: true)])
        let service = PornHubAuthService(store: store, helper: AuthHelper(), now: { Date(timeIntervalSince1970: 1_784_000_000) })
        var status = await service.status()
        XCTAssertEqual(status.state, .signedIn)
        await service.recordYtDlpFailure(.authenticationUnsupported)
        status = await service.status()
        XCTAssertEqual(status.state, .signedIn)
        await service.recordYtDlpFailure(.temporarilyUnavailable)
        status = await service.status()
        XCTAssertEqual(status.state, .signedIn)
        await service.recordYtDlpFailure(.sessionExpired)
        status = await service.status()
        XCTAssertEqual(status.state, .expired)
    }
}

private final class AuthCookieStore: PornHubCookieStore, @unchecked Sendable {
    private let cookies: [PornHubCookieRecord]
    init(cookies: [PornHubCookieRecord]) { self.cookies = cookies }
    func load() throws -> [PornHubCookieRecord] { cookies }
    func save(_ cookies: [PornHubCookieRecord]) throws {}
    func remove() throws {}
}

private struct AuthHelper: PornHubAuthHelping {
    func login() async throws -> PornHubHelperResult { .signedOut }
    func logout() async throws {}
}
