import XCTest
@testable import LustreCore
@testable import LustreAgent

final class AgentHLSTransferTests: XCTestCase {
    func testLocalHLSUsesMaterializerAndDirectMediaUsesDownloader() async throws {
        let root = temporaryDirectory()
        let tracker = TransferTracker()
        let service = try AgentService(
            databaseURL: root.appendingPathComponent("jobs.sqlite3"),
            resolver: fixtureResolver(),
            downloadsDirectory: root.appendingPathComponent("downloads"),
            progressDownloader: { _, _, directory, _ in
                await tracker.recordDirect()
                return directory.appendingPathComponent("direct.mp4")
            },
            hlsMaterializer: { _, quality, directory, _ in
                await tracker.recordMaterialization(quality: quality, directory: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let output = directory.appendingPathComponent("materialized.mp4")
                try Data("media".utf8).write(to: output)
                return output
            }
        )

        let hls = try await service.createJob(CreateJobRequest(sourcePageURL: URL(string: "https://vidara.so/v/code")!))
        try await waitForCompletion(hls.id, service: service)
        let materializations = await tracker.materializations()
        let directBefore = await tracker.directDownloads()
        XCTAssertEqual(materializations, 1)
        XCTAssertEqual(directBefore, 0)

        let direct = try await service.createJob(CreateJobRequest(sourcePageURL: URL(string: "https://media.example/video.mp4")!))
        try await waitForCompletion(direct.id, service: service)
        let directAfter = await tracker.directDownloads()
        XCTAssertEqual(directAfter, 1)
    }

    func testWebDAVHLSUploadsFinalizedFileAndCleansStaging() async throws {
        let root = temporaryDirectory()
        let tracker = TransferTracker()
        let secrets = HLSTestSecrets()
        let profiles = try RemoteDestinationProfileStore(fileURL: root.appendingPathComponent("destinations.json"))
        let service = try AgentService(
            databaseURL: root.appendingPathComponent("jobs.sqlite3"),
            resolver: fixtureResolver(),
            destinationProfiles: profiles,
            destinationSecrets: secrets,
            hlsMaterializer: { _, _, directory, _ in
                await tracker.recordStaging(directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let output = directory.appendingPathComponent("final.mp4")
                try Data("finalized media".utf8).write(to: output)
                return output
            },
            stagedRemoteUploader: { _, _, file, profile, password, _ in
                XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "finalized media")
                XCTAssertEqual(password, "fixture-password")
                await tracker.recordUpload(file)
                return profile.baseURL.appendingPathComponent(file.lastPathComponent)
            }
        )
        let profile = try await service.saveWebDAVDestination(WebDAVDestinationRequest(
            name: "Fixture", baseURL: URL(string: "https://webdav.example")!,
            username: "fixture", password: "fixture-password", remotePath: "/media"
        ))
        let job = try await service.createJob(CreateJobRequest(
            sourcePageURL: URL(string: "https://vidara.so/v/code")!,
            destination: RemoteDestination.webDAV(profile.id)
        ))

        try await waitForCompletion(job.id, service: service)
        let uploads = await tracker.uploads()
        let stagingValue = await tracker.stagingDirectory()
        XCTAssertEqual(uploads, 1)
        let staging = try XCTUnwrap(stagingValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testCancellingWebDAVHLSCleansStagingAndDoesNotUpload() async throws {
        let root = temporaryDirectory()
        let tracker = TransferTracker()
        let secrets = HLSTestSecrets()
        let service = try AgentService(
            databaseURL: root.appendingPathComponent("jobs.sqlite3"),
            resolver: fixtureResolver(),
            destinationProfiles: try RemoteDestinationProfileStore(fileURL: root.appendingPathComponent("destinations.json")),
            destinationSecrets: secrets,
            hlsMaterializer: { _, _, directory, _ in
                await tracker.recordStaging(directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("partial".utf8).write(to: directory.appendingPathComponent("partial.mp4"))
                try await Task.sleep(for: .seconds(60))
                return directory.appendingPathComponent("partial.mp4")
            },
            stagedRemoteUploader: { _, _, file, profile, _, _ in
                await tracker.recordUpload(file)
                return profile.baseURL
            }
        )
        let profile = try await service.saveWebDAVDestination(WebDAVDestinationRequest(
            name: "Fixture", baseURL: URL(string: "https://webdav.example")!,
            username: "fixture", password: "fixture-password", remotePath: "/media"
        ))
        let job = try await service.createJob(CreateJobRequest(
            sourcePageURL: URL(string: "https://vidara.so/v/code")!,
            destination: RemoteDestination.webDAV(profile.id)
        ))
        for _ in 0..<200 {
            if await tracker.stagingDirectory() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await service.apply(.cancel, to: job.id)
        let stagingValue = await tracker.stagingDirectory()
        let staging = try XCTUnwrap(stagingValue)
        for _ in 0..<200 {
            if !FileManager.default.fileExists(atPath: staging.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let uploads = await tracker.uploads()
        XCTAssertEqual(uploads, 0)
    }

    private func fixtureResolver() -> StaticProviderResolver {
        StaticProviderResolver(requestFetch: { request in
            if request.url.path == "/api/stream" {
                return HTTPPage(body: #"{"streaming_url":"https://media.example/master.m3u8","title":"Fixture"}"#, finalURL: request.url, statusCode: 200)
            }
            return HTTPPage(body: "#EXTM3U", finalURL: request.url, statusCode: 200)
        })
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lustre-hls-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private actor TransferTracker {
    private var materializationCount = 0
    private var directCount = 0
    private var uploadCount = 0
    private var staging: URL?

    func recordMaterialization(quality: ResolvedQuality, directory: URL) {
        XCTAssertEqual(quality.mediaKind, .hls)
        materializationCount += 1
    }
    func recordDirect() { directCount += 1 }
    func recordStaging(_ directory: URL) { staging = directory }
    func recordUpload(_ file: URL) {
        XCTAssertEqual(file.pathExtension, "mp4")
        uploadCount += 1
    }
    func materializations() -> Int { materializationCount }
    func directDownloads() -> Int { directCount }
    func uploads() -> Int { uploadCount }
    func stagingDirectory() -> URL? { staging }
}

private final class HLSTestSecrets: RemoteDestinationSecretStore, @unchecked Sendable {
    private var values: [UUID: String] = [:]
    func password(for profileID: UUID) throws -> String? { values[profileID] }
    func save(password: String, for profileID: UUID) throws { values[profileID] = password }
    func remove(profileID: UUID) throws { values[profileID] = nil }
}
