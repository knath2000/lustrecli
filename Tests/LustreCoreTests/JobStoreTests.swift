import Foundation
import LustreCore
import XCTest

final class JobStoreTests: XCTestCase {
    func testPersistsSourcePageAndUpdatesAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JobStore(databaseURL: directory.appending(path: "jobs.sqlite3"))
        let job = DownloadJob(sourcePageURL: URL(string: "https://example.com/watch/123")!, preferredQualityLabel: "1080p", status: .failed)

        try await store.create(job)
        let retried = try await store.apply(.retry, to: job.id)

        XCTAssertEqual(retried.sourcePageURL, job.sourcePageURL)
        XCTAssertEqual(retried.preferredQualityLabel, "1080p")
        XCTAssertEqual(retried.status, .queued)
        XCTAssertEqual(retried.attempts, 1)
    }

    func testRejectsActionsThatAreInvalidForTheCurrentJobState() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JobStore(databaseURL: directory.appending(path: "jobs.sqlite3"))
        let completed = DownloadJob(
            sourcePageURL: URL(string: "https://example.com/completed")!,
            status: .completed,
            message: "Completed."
        )
        let running = DownloadJob(
            sourcePageURL: URL(string: "https://example.com/running")!,
            status: .running,
            message: "Downloading."
        )
        let verificationRequired = DownloadJob(
            sourcePageURL: URL(string: "https://example.com/verification")!,
            status: .verificationRequired,
            message: "Provider requires verification."
        )
        try await store.create(completed)
        try await store.create(running)
        try await store.create(verificationRequired)

        await XCTAssertThrowsErrorAsync(try await store.apply(.retry, to: completed.id))
        await XCTAssertThrowsErrorAsync(try await store.apply(.retry, to: running.id))
        let unchangedRunning = try await store.job(id: running.id)
        XCTAssertEqual(unchangedRunning?.status, .running)
        XCTAssertEqual(unchangedRunning?.attempts, 0)

        let retried = try await store.apply(.retry, to: verificationRequired.id)
        XCTAssertEqual(retried.status, .queued)
        XCTAssertEqual(retried.attempts, 1)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
    }
}
