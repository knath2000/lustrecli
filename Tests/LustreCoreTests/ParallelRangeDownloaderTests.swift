import Foundation
import LustreAgent
import LustreCore
import XCTest

final class ParallelRangeDownloaderTests: XCTestCase {
    func testResumeStateRoundTrips() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let state = DownloadResumeState(
            byteOffset: 1024,
            totalBytes: 4096,
            etag: "abc",
            lastModified: "Wed, 21 Oct 2026 07:28:00 GMT",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            rangesCompleted: [0...1023, 1024...2047]
        )
        let data = try encoder.encode(state)
        let decoded = try decoder.decode(DownloadResumeState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testResumeStateFreshness() {
        let fresh = DownloadResumeState(startedAt: .now)
        XCTAssertTrue(fresh.isFresh(ttlHours: 72))
        let stale = DownloadResumeState(startedAt: .now.addingTimeInterval(-3600 * 73))
        XCTAssertFalse(stale.isFresh(ttlHours: 72))
    }

    func testDownloadJobDefaultsToNilResumeState() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "jobstore-resume-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JobStore(databaseURL: directory)
        let job = DownloadJob(sourcePageURL: URL(string: "https://example.com/video")!, title: "Title")
        try await store.create(job)
        let loaded = try await store.job(id: job.id)
        XCTAssertEqual(loaded?.resumeState, nil)
    }

    func testDownloadJobPersistsResumeState() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "jobstore-resume-persist-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JobStore(databaseURL: directory)
        let resume = DownloadResumeState(byteOffset: 512, totalBytes: 1024, etag: "etag", lastModified: nil, startedAt: .now, rangesCompleted: [0...511])
        let job = DownloadJob(sourcePageURL: URL(string: "https://example.com/video")!, resumeState: resume)
        try await store.create(job)
        let loaded = try await store.job(id: job.id)
        XCTAssertEqual(loaded?.resumeState, resume)
    }

    func testRemoveJobDeletesPartialDirectory() async throws {
        let jobID = UUID()
        let directory = ParallelRangeDownloader.partialDirectory(for: jobID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appending(path: "sentinel.part")
        try Data(repeating: 0, count: 64).write(to: sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        ParallelRangeDownloader.removePartials(for: jobID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
