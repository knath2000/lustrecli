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

    func testRetryDiscardsBrowserAssistanceButKeepsStableSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JobStore(databaseURL: directory.appending(path: "jobs.sqlite3"))
        let selector = StableQualitySelector(provider: .doodStream, mediaKind: .direct)
        let assistance = AssistedResolution(
            mediaURL: URL(string: "https://media.example/temporary.mp4")!,
            headers: ["Referer": "https://dood.example/"],
            mediaKind: .direct,
            title: "Scene",
            resolutionMethod: "WebView"
        )
        let job = DownloadJob(
            sourcePageURL: URL(string: "https://dood.example/e/scene")!,
            qualitySelector: selector,
            assistedResolution: assistance,
            status: .verificationRequired
        )
        try await store.create(job)

        let retried = try await store.apply(.retry, to: job.id)

        XCTAssertNil(retried.assistedResolution)
        XCTAssertEqual(retried.qualitySelector, selector)
        XCTAssertEqual(retried.sourcePageURL, job.sourcePageURL)
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

    func testForceStartIsValidOnlyForQueuedJobsAndKeepsThemQueued() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JobStore(databaseURL: directory.appending(path: "jobs.sqlite3"))
        let queued = DownloadJob(sourcePageURL: URL(string: "https://example.com/queued")!)
        try await store.create(queued)

        let forceStarted = try await store.apply(.forceStart, to: queued.id)

        XCTAssertEqual(forceStarted.status, .queued)
        XCTAssertEqual(forceStarted.message, "Force start requested; bypassing normal concurrency limit.")

        for status in [JobStatus.running, .paused, .completed, .failed, .cancelled, .verificationRequired] {
            let job = DownloadJob(sourcePageURL: URL(string: "https://example.com/\(status.rawValue)")!, status: status)
            try await store.create(job)
            await XCTAssertThrowsErrorAsync(try await store.apply(.forceStart, to: job.id))
        }
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
