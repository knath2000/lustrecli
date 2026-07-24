import XCTest
@testable import LustreAgent
@testable import LustreCore

final class YtDlpProgressEventBufferTests: XCTestCase {
    func testFirstAndLatestSameCategoryArePreserved() throws {
        var buffer = YtDlpProgressEventBuffer(capacity: 4)
        try buffer.offer(sample(.materializing, .downloading, .video, 1))
        try buffer.offer(sample(.materializing, .downloading, .video, 2))
        try buffer.offer(sample(.materializing, .downloading, .video, 3))
        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.popFirst()?.progress.bytesWritten, 1)
        XCTAssertEqual(buffer.popFirst()?.progress.bytesWritten, 3)
        XCTAssertNil(buffer.popFirst())
    }

    func testTransitionsFinishedAndCapacityArePreserved() throws {
        var buffer = YtDlpProgressEventBuffer(capacity: 3)
        try buffer.offer(sample(.materializing, .downloading, .video, 1))
        try buffer.offer(sample(.materializing, .downloading, .audio, 2))
        try buffer.offer(sample(.postProcessing, .postProcessing, .media, 3))
        XCTAssertThrowsError(try buffer.offer(sample(.materializing, .finished, .media, 4))) { XCTAssertEqual($0 as? YtDlpProgressEventBufferError, .capacityExceeded) }
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.popFirst()?.component, .video)
        XCTAssertEqual(buffer.popFirst()?.component, .audio)
        XCTAssertEqual(buffer.popFirst()?.phase, .postProcessing)
    }

    func testResetAndFinishedCoalescing() throws {
        var buffer = YtDlpProgressEventBuffer(capacity: 1)
        try buffer.offer(sample(.materializing, .finished, .media, 1))
        try buffer.offer(sample(.materializing, .finished, .media, 2))
        XCTAssertEqual(buffer.popFirst()?.progress.bytesWritten, 1)
        XCTAssertEqual(buffer.popFirst()?.progress.bytesWritten, 2)
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
    }

    private func sample(_ phase: TransferPhase, _ status: YtDlpProgressStatus, _ component: YtDlpProgressComponent, _ bytes: Int64) -> YtDlpProgressSample {
        YtDlpProgressSample(status: status, component: component, phase: phase, message: "safe", progress: DownloadProgress(bytesWritten: bytes, totalBytes: 10, phase: phase))
    }
}
