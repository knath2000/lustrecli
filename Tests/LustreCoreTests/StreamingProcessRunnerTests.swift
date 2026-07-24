import XCTest
@testable import LustreAgent

final class StreamingProcessRunnerTests: XCTestCase {
    func testEmitsProgressBeforeFixtureExitAndBoundsDiagnostics() async throws {
        let release = FileManager.default.temporaryDirectory.appendingPathComponent("lustre-stream-release-\(UUID().uuidString)")
        let executable = try fixture("printf 'LUSTRE_PROGRESS:v1\tdownloading\t1\t2\tNA\tNA\tNA\tNA\tNA\tvideo\\n' >&2; while [ ! -f '\(release.path)' ]; do sleep 0.02; done; printf 'noise' >&2")
        let recorder = ProgressRecorder()
        let result = try await StreamingProcessRunner.run(executable: executable, arguments: [], timeout: 3, stdoutCap: 64, stderrCap: 64) { _ in recorder.record(); FileManager.default.createFile(atPath: release.path, contents: nil) }
        let recorded = recorder.elapsed()
        XCTAssertTrue(recorded)
        XCTAssertEqual(String(decoding: result.stderrDiagnostics, as: UTF8.self), "noise\n")
    }

    private func fixture(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lustre-stream-\(UUID().uuidString)")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func record() { lock.lock(); value = true; lock.unlock() }
    func elapsed() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
