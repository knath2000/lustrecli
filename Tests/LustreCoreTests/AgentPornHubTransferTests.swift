import XCTest
@testable import LustreCore
@testable import LustreAgent

final class AgentPornHubTransferTests: XCTestCase {
    func testExtractRoutesCanonicalPornHubToInjectedAgentResolver() async throws {
        let root = temporaryDirectory()
        let source = URL(string: "https://www.pornhub.com/view_video.php?viewkey=ph-test")!
        let tracker = PornHubTransferTracker()
        let service = try AgentService(
            databaseURL: root.appendingPathComponent("jobs.sqlite3"),
            automaticallyStartsDownloads: false,
            pornHubResolver: { url in
                await tracker.recordResolved(url)
                return Self.resolution(source)
            }
        )
        let result = try await service.extract(url: source)
        XCTAssertEqual(result.resolution?.provider, .pornHub)
        let resolvedURL = await tracker.resolvedURL()
        XCTAssertEqual(resolvedURL, source)
        XCTAssertTrue(result.resolution?.qualities.allSatisfy { $0.url == source } == true)
    }

    func testLocalPornHubJobUsesInjectedYtDlpMaterializer() async throws {
        let root = temporaryDirectory()
        let source = URL(string: "https://www.pornhub.com/view_video.php?viewkey=ph-local")!
        let tracker = PornHubTransferTracker()
        let service = try AgentService(
            databaseURL: root.appendingPathComponent("jobs.sqlite3"),
            downloadsDirectory: root.appendingPathComponent("downloads"),
            pornHubResolver: { _ in Self.resolution(source) },
            ytDlpMaterializer: { _, quality, directory, _ in
                await tracker.recordMaterialized(quality, directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let output = directory.appendingPathComponent("public.mp4")
                try Data(repeating: 1, count: 2_048).write(to: output)
                return output
            }
        )
        let job = try await service.createJob(CreateJobRequest(sourcePageURL: source, preferredQualityLabel: "720p MP4"))
        try await waitForCompletion(job.id, service: service)
        let materializations = await tracker.materializations()
        let selector = await tracker.selector()
        XCTAssertEqual(materializations, 1)
        XCTAssertEqual(selector, "h720")
    }

    func testWebDAVPornHubUsesUniqueStagingAndCleansIt() async throws {
        let root = temporaryDirectory()
        let source = URL(string: "https://www.pornhub.com/view_video.php?viewkey=ph-webdav")!
        let tracker = PornHubTransferTracker()
        let secrets = PornHubTestSecrets()
        let service = try AgentService(
            databaseURL: root.appendingPathComponent("jobs.sqlite3"),
            destinationProfiles: try RemoteDestinationProfileStore(fileURL: root.appendingPathComponent("destinations.json")),
            destinationSecrets: secrets,
            pornHubResolver: { _ in Self.resolution(source) },
            ytDlpMaterializer: { _, _, directory, _ in
                await tracker.recordStaging(directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let output = directory.appendingPathComponent("public.mp4")
                try Data(repeating: 1, count: 2_048).write(to: output)
                return output
            },
            stagedRemoteUploader: { _, _, file, profile, password, _ in
                XCTAssertEqual(password, "fixture-password")
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                return profile.baseURL.appendingPathComponent(file.lastPathComponent)
            }
        )
        let profile = try await service.saveWebDAVDestination(WebDAVDestinationRequest(
            name: "Fixture", baseURL: URL(string: "https://webdav.example")!,
            username: "fixture", password: "fixture-password", remotePath: "/media"
        ))
        let job = try await service.createJob(CreateJobRequest(sourcePageURL: source, destination: RemoteDestination.webDAV(profile.id)))
        try await waitForCompletion(job.id, service: service)
        let stagingValue = await tracker.staging()
        let staging = try XCTUnwrap(stagingValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    private static func resolution(_ source: URL) -> ProviderResolution {
        ProviderResolution(
            sourcePageURL: source,
            provider: .pornHub,
            title: "Public",
            qualities: [ResolvedQuality(
                label: "720p MP4", url: source, resolutionMethod: "fixture",
                mediaKind: .ytDlp, formatSelector: "h720"
            )],
            trace: ["fixture"]
        )
    }

    private func waitForCompletion(_ id: UUID, service: AgentService) async throws {
        for _ in 0..<200 {
            if let job = try await service.allJobs().first(where: { $0.id == id }), [.completed, .failed].contains(job.status) {
                XCTAssertEqual(job.status, .completed, job.message)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for job")
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lustre-pornhub-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private actor PornHubTransferTracker {
    private var resolved: URL?
    private var count = 0
    private var format: String?
    private var stagingDirectory: URL?
    func recordResolved(_ url: URL) { resolved = url }
    func recordMaterialized(_ quality: ResolvedQuality, _ directory: URL) {
        count += 1
        format = quality.formatSelector
    }
    func recordStaging(_ directory: URL) { stagingDirectory = directory }
    func resolvedURL() -> URL? { resolved }
    func materializations() -> Int { count }
    func selector() -> String? { format }
    func staging() -> URL? { stagingDirectory }
}

private final class PornHubTestSecrets: RemoteDestinationSecretStore, @unchecked Sendable {
    private var values: [UUID: String] = [:]
    func password(for profileID: UUID) throws -> String? { values[profileID] }
    func save(password: String, for profileID: UUID) throws { values[profileID] = password }
    func remove(profileID: UUID) throws { values[profileID] = nil }
}
