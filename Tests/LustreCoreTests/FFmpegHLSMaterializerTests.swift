import XCTest
@testable import LustreCore
@testable import LustreAgent

final class FFmpegHLSMaterializerTests: XCTestCase {
    func testArgumentsBuildSortedCRLFTerminatedHeaders() throws {
        let quality = ResolvedQuality(
            label: "720p",
            url: URL(string: "https://media.example/master.m3u8?token=signed")!,
            headers: ["User-Agent": "Fixture", "Referer": "https://embed.example/e/code"],
            resolutionMethod: "fixture",
            mediaKind: .hls
        )
        let partial = URL(fileURLWithPath: "/tmp/fixture.mp4.part")

        let arguments = try FFmpegHLSMaterializer.arguments(for: quality, partial: partial)

        let headersIndex = try XCTUnwrap(arguments.firstIndex(of: "-headers"))
        XCTAssertEqual(
            arguments[headersIndex + 1],
            "Referer: https://embed.example/e/code\r\nUser-Agent: Fixture\r\n"
        )
        XCTAssertEqual(arguments.suffix(2), ["mp4", partial.path])
        XCTAssertTrue(arguments.contains("-progress"))
        XCTAssertTrue(arguments.contains("-reconnect"))
        XCTAssertTrue(arguments.contains("-rw_timeout"))
        XCTAssertFalse(arguments.contains("+faststart"))
    }

    func testArgumentsRejectHeaderCRLFInjection() {
        let quality = ResolvedQuality(
            label: "HLS",
            url: URL(string: "https://media.example/master.m3u8")!,
            headers: ["Referer": "https://embed.example/\r\nX-Injected: yes"],
            resolutionMethod: "fixture",
            mediaKind: .hls
        )

        XCTAssertThrowsError(try FFmpegHLSMaterializer.arguments(
            for: quality,
            partial: URL(fileURLWithPath: "/tmp/fixture.part")
        ))
    }

    func testCancellationTerminatesProcessWithoutFFmpeg() async throws {
        let task = Task {
            try await FFmpegHLSMaterializer.runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/yes"),
                arguments: [],
                timeout: 60
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testStalledProcessIsTerminated() async throws {
        do {
            _ = try await FFmpegHLSMaterializer.runProcess(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 5"],
                timeout: 10,
                stallTimeout: 0.2,
                onProgress: { _ in }
            )
            XCTFail("Expected stalled transfer")
        } catch HLSMaterializationError.stalled {
        } catch {
            XCTFail("Expected stalled transfer, got \(error)")
        }
    }
}
