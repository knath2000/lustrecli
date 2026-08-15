import XCTest
@testable import LustreAgent
@testable import LustreCore

final class GoogleDriveProgressTests: XCTestCase {
    func testParsesRcloneStatsAsUploadProgress() throws {
        let line = Data(#"{"level":"info","stats":{"bytes":67108864,"speed":8388608,"eta":12.2,"totalBytes":100000000}}"#.utf8)

        let progress = try XCTUnwrap(GoogleDriveClient.rcloneProgress(line, expectedSize: 100_000_000))

        XCTAssertEqual(progress.bytesWritten, 67_108_864)
        XCTAssertEqual(progress.totalBytes, 100_000_000)
        XCTAssertEqual(progress.phase, .uploading)
        XCTAssertEqual(progress.bytesPerSecond, 8_388_608)
        XCTAssertEqual(progress.etaSeconds, 13)
    }

    func testIgnoresNonStatsLogsAndClampsCompletedBytes() throws {
        XCTAssertNil(GoogleDriveClient.rcloneProgress(Data(#"{"level":"info","msg":"Starting"}"#.utf8), expectedSize: 100))
        let progress = try XCTUnwrap(GoogleDriveClient.rcloneProgress(Data(#"{"stats":{"bytes":120,"totalBytes":240}}"#.utf8), expectedSize: 100))
        XCTAssertEqual(progress.bytesWritten, 100)
        XCTAssertEqual(progress.fraction, 1)
    }
}
