import Foundation
import LustreAgent
import LustreCore
import XCTest

final class AgentServiceTests: XCTestCase {
    func testExtractSurfacesStaticProviderResolution() async throws {
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                HTTPPage(
                    body: #"<script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-service-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let service = try AgentService(databaseURL: database, resolver: resolver)

        let result = try await service.extract(url: URL(string: "https://mixdrop.co/e/xyz")!)

        XCTAssertEqual(result.resolutionState, "resolved")
        XCTAssertEqual(result.resolution?.provider, .mixDrop)
        XCTAssertEqual(result.resolution?.qualities.first?.url.absoluteString, "https://cdn.mxcontent.net/video.mp4")
    }
}
