import Foundation
import LustreCore
import XCTest

final class JobStoreTests: XCTestCase {
    func testPersistsSourcePageAndUpdatesAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JobStore(databaseURL: directory.appending(path: "jobs.sqlite3"))
        let job = DownloadJob(sourcePageURL: URL(string: "https://example.com/watch/123")!, preferredQualityLabel: "1080p")

        try await store.create(job)
        let retried = try await store.apply(.retry, to: job.id)

        XCTAssertEqual(retried.sourcePageURL, job.sourcePageURL)
        XCTAssertEqual(retried.preferredQualityLabel, "1080p")
        XCTAssertEqual(retried.status, .queued)
        XCTAssertEqual(retried.attempts, 1)
    }
}
