import Foundation
@testable import LustreAgent
import LustreCore
import XCTest

final class GenericYtDlpTests: XCTestCase {
    func testGenericMetadataProjectionKeepsSelectorsButNotMediaURLs() throws {
        let source = URL(string: "https://www.eporner.com/video-example")!
        let data = Data(#"""
        {
          "title":"Example",
          "thumbnail":"https://cdn.example.com/thumb.jpg",
          "formats":[
            {"format_id":"audio","acodec":"aac","vcodec":"none","abr":128,"url":"https://cdn.example.com/audio.m4a"},
            {"format_id":"video1080","acodec":"none","vcodec":"h264","height":1080,"ext":"mp4","url":"https://cdn.example.com/video.mp4"}
          ]
        }
        """#.utf8)

        let resolution = try PornHubYtDlp.parseGenericMetadata(data, source: source)

        XCTAssertEqual(resolution.provider, .ytDlp)
        XCTAssertEqual(resolution.sourcePageURL, source)
        XCTAssertEqual(resolution.qualities.map(\.label), ["1080p MP4"])
        XCTAssertEqual(resolution.qualities.map(\.formatSelector), ["video1080+audio"])
        XCTAssertEqual(resolution.qualities.map(\.url), [source])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(resolution), as: UTF8.self).contains("cdn.example.com/video.mp4"))
    }

    func testGenericArgumentsRequirePublicHTTPSAndBoundedSelector() throws {
        let source = URL(string: "https://example.com/watch/123")!
        let directory = URL(fileURLWithPath: "/tmp/lustre-generic-test")

        XCTAssertEqual(try PornHubYtDlp.genericMetadataArguments(source: source).last, source.absoluteString)
        XCTAssertTrue(try PornHubYtDlp.genericMaterializationArguments(source: source, formatSelector: "v1+a1", directory: directory).contains("v1+a1"))
        XCTAssertThrowsError(try PornHubYtDlp.genericMetadataArguments(source: URL(string: "http://example.com/watch")!))
        XCTAssertThrowsError(try PornHubYtDlp.genericMetadataArguments(source: URL(string: "https://127.0.0.1/watch")!))
        XCTAssertThrowsError(try PornHubYtDlp.genericMaterializationArguments(source: source, formatSelector: "best;rm", directory: directory))
    }
}
