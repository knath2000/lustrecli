import XCTest
@testable import LustreAgent
@testable import LustreCore

final class YtDlpProgressEventMailboxTests: XCTestCase {
    func testBufferedCloseAndFailureSemantics() async throws {
        let mailbox = YtDlpProgressEventMailbox(capacity: 2)
        try await mailbox.offer(sample(1))
        let first = try await mailbox.next()
        XCTAssertEqual(first?.progress.bytesWritten, 1)
        await mailbox.close()
        let closed = try await mailbox.next()
        XCTAssertNil(closed)
        await XCTAssertThrowsErrorAsync(try await mailbox.offer(sample(2))) { XCTAssertEqual($0 as? YtDlpProgressEventMailboxError, .closed) }

        let failed = YtDlpProgressEventMailbox(capacity: 2)
        try await failed.offer(sample(1))
        await failed.fail()
        await XCTAssertThrowsErrorAsync(try await failed.next()) { XCTAssertEqual($0 as? YtDlpProgressEventMailboxError, .failed) }
    }

    private func sample(_ bytes: Int64) -> YtDlpProgressSample {
        YtDlpProgressSample(status: .downloading, component: .video, phase: .materializing, message: "safe", progress: DownloadProgress(bytesWritten: bytes, totalBytes: 10, phase: .materializing))
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ verify: ((Error) -> Void)? = nil) async {
    do { _ = try await expression(); XCTFail("Expected error") } catch { verify?(error) }
}
