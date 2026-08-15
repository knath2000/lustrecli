import Foundation
import XCTest
@testable import LustreAgent
@testable import LustreCore

final class CloudLibraryTests: XCTestCase {
    func testSnapshotProjectsOnlySanitizedDestinationState() async throws {
        let stateURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "library.json")
        let store = CloudLibraryStore(stateURL: stateURL)
        let job = DownloadJob(
            id: UUID(),
            sourcePageURL: URL(string: "https://pmvhaven.com/video/example")!,
            preferredQualityLabel: "2160p",
            destination: "gdrive:\(UUID().uuidString)",
            status: .completed,
            message: "Completed",
            attempts: 1
        )
        let snapshot = await store.snapshot(jobs: [job], page: 1)
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].pipeline.first?.destination, "Google Drive")
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("gdrive:"))
        XCTAssertFalse(encoded.contains("mediaURL"))
        XCTAssertFalse(encoded.contains("Path"))
    }

    func testOrganizationIsBoundedAndRemovalKeepsJobUntouched() async throws {
        let stateURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "library.json")
        let store = CloudLibraryStore(stateURL: stateURL)
        let job = DownloadJob(sourcePageURL: URL(string: "https://example.com/video")!, status: .completed, message: "Completed")
        let updated = try await store.update(id: job.id, tags: Array(repeating: "tag", count: 30), collection: String(repeating: "x", count: 100), favorite: true, jobs: [job])
        XCTAssertEqual(updated.items[0].tags.count, 1)
        XCTAssertEqual(updated.items[0].collection?.count, 80)
        XCTAssertTrue(updated.items[0].favorite)
        let removed = try await store.remove(id: job.id, jobs: [job])
        XCTAssertTrue(removed.items.isEmpty)
        XCTAssertEqual(job.status, .completed)
    }
}
