import Foundation
import LustreCore
import XCTest

final class AgentConfigurationTests: XCTestCase {
    func testDefaultsHaveParallelRangeDisabled() {
        let configuration = AgentConfiguration.default
        XCTAssertFalse(configuration.downloadParallelRangeEnabled)
        XCTAssertEqual(configuration.downloadMaxStreamsPerJob, 8)
        XCTAssertEqual(configuration.downloadResumeTTLHours, 72)
        XCTAssertFalse(configuration.downloadBenchEnabled)
    }

    func testMaxStreamsClampedToEight() {
        let configuration = AgentConfiguration(downloadMaxStreamsPerJob: 32)
        XCTAssertEqual(configuration.downloadMaxStreamsPerJob, 8)
    }

    func testResumeTTLFlooredAtOneHour() {
        let configuration = AgentConfiguration(downloadResumeTTLHours: 0)
        XCTAssertEqual(configuration.downloadResumeTTLHours, 1)
    }

    func testRoundTripsThroughJSON() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agent-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = AgentConfiguration(
            downloadParallelRangeEnabled: true,
            downloadMaxStreamsPerJob: 4,
            downloadResumeTTLHours: 12,
            downloadBenchEnabled: true
        )
        try configuration.write(to: directory)
        let loaded = AgentConfiguration.load(from: directory)
        XCTAssertEqual(loaded.downloadParallelRangeEnabled, true)
        XCTAssertEqual(loaded.downloadMaxStreamsPerJob, 4)
        XCTAssertEqual(loaded.downloadResumeTTLHours, 12)
        XCTAssertEqual(loaded.downloadBenchEnabled, true)
    }

    func testLoadReturnsDefaultWhenFileMissing() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "agent-config-missing-\(UUID().uuidString).json")
        let loaded = AgentConfiguration.load(from: missing)
        XCTAssertEqual(loaded, .default)
    }
}
