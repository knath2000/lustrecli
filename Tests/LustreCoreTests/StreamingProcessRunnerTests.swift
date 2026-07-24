import XCTest
import Darwin
@testable import LustreAgent

final class StreamingProcessRunnerTests: XCTestCase {
    func testEmitsProgressBeforeFixtureExitAndBoundsDiagnostics() async throws {
        let fixture = try Fixture()
        let release = fixture.url.appendingPathComponent("release")
        let executable = try fixture.script("printf 'LUSTRE_PROGRESS:v1\\tdownloading\\t1\\t2\\tNA\\tNA\\tNA\\tNA\\tNA\\tvideo\\n' >&2; while [ ! -f '\(release.path)' ]; do sleep 0.02; done; printf 'noise' >&2")
        let recorder = ProgressRecorder()

        let result = try await StreamingProcessRunner.run(executable: executable, arguments: [], timeout: 3, stdoutCap: 64, stderrCap: 64) { _ in
            await recorder.record(1)
            FileManager.default.createFile(atPath: release.path, contents: nil)
        }

        let values = await recorder.values()
        XCTAssertEqual(values, [1])
        XCTAssertEqual(String(decoding: result.stderrDiagnostics, as: UTF8.self), "noise\n")
    }

    func testTransitionsCRLFAndFinalUnterminatedProgressAreDeliveredInOrder() async throws {
        let fixture = try Fixture()
        let executable = try fixture.script("printf 'LUSTRE_PROGRESS:v1\\tdownloading\\t1\\t2\\tNA\\tNA\\tNA\\tNA\\tNA\\tvideo\\rLUSTRE_PROGRESS:v1\\tdownloading\\t2\\t2\\tNA\\tNA\\tNA\\tNA\\tNA\\taudio\\r\\nLUSTRE_PROGRESS:v1\\tpostprocessing\\t2\\t2\\tNA\\tNA\\tNA\\tNA\\tNA\\tmedia\\nLUSTRE_PROGRESS:v1\\tfinished\\t2\\t2\\tNA\\tNA\\tNA\\tNA\\tNA\\tmedia' >&2")
        let recorder = ProgressRecorder()

        let result = try await StreamingProcessRunner.run(executable: executable, arguments: [], timeout: 3, stdoutCap: 0, stderrCap: 64) { sample in
            await recorder.record(sample.progress.bytesWritten)
        }

        let values = await recorder.values()
        XCTAssertEqual(values, [1, 2, 2, 2])
        XCTAssertTrue(result.stderrDiagnostics.isEmpty)
    }

    func testSlowCallbackDoesNotBlockStderrDrainage() async throws {
        let fixture = try Fixture()
        let checkpoint = fixture.url.appendingPathComponent("checkpoint")
        let pid = fixture.url.appendingPathComponent("pid")
        let executable = try fixture.script("echo $$ > '\(pid.path)'; printf 'LUSTRE_PROGRESS:v1\\tdownloading\\t1\\t5000\\tNA\\tNA\\tNA\\tNA\\tNA\\tvideo\\n' >&2; i=2; while [ $i -le 5000 ]; do printf 'LUSTRE_PROGRESS:v1\\tdownloading\\t%s\\t5000\\tNA\\tNA\\tNA\\tNA\\tNA\\tvideo\\n' $i >&2; i=$((i + 1)); done; touch '\(checkpoint.path)'")
        let gate = CallbackGate()
        let recorder = ProgressRecorder()
        let task = Task<Result<StreamingProcessResult, Error>, Never> {
            do {
                return .success(try await StreamingProcessRunner.run(executable: executable, arguments: [], timeout: 10, stdoutCap: 0, stderrCap: 64) { sample in
                    await recorder.record(sample.progress.bytesWritten)
                    if sample.progress.bytesWritten == 1 { await gate.wait() }
                })
            } catch {
                return .failure(error)
            }
        }

        do {
            try await waitForFile(checkpoint)
            let waiting = await gate.isWaiting()
            XCTAssertTrue(waiting)
        } catch {
            await gate.release()
            _ = await task.value
            throw error
        }

        await gate.release()
        let result = await task.value
        switch result {
        case .success(let output):
            XCTAssertTrue(output.stderrDiagnostics.isEmpty)
        case .failure(let error):
            XCTFail("Unexpected runner error: \(error)")
        }
        let values = await recorder.values()
        XCTAssertEqual(values.first, 1)
        XCTAssertEqual(values.last, 5000)
        XCTAssertFalse(try processExists(pid))
    }

    func testPartialProgressAndFinalDiagnosticUseBoundedNormalizedRetention() async throws {
        let fixture = try Fixture()
        let executable = try fixture.script("{ printf 'LUSTRE_PROGRESS:v1\\tdownloading\\t'; printf '1\\t2\\tNA\\tNA\\tNA\\tNA\\tNA\\tvideo\\nabc'; } >&2")
        let recorder = ProgressRecorder()

        let result = try await StreamingProcessRunner.run(executable: executable, arguments: [], timeout: 3, stdoutCap: 0, stderrCap: 4) { sample in
            await recorder.record(sample.progress.bytesWritten)
        }

        let values = await recorder.values()
        XCTAssertEqual(values, [1])
        XCTAssertEqual(String(decoding: result.stderrDiagnostics, as: UTF8.self), "abc\n")
    }

    func testStdoutCapsDrainAndRetainExactPrefix() async throws {
        let fixture = try Fixture()
        let executable = try fixture.script("printf 'abcdef'; printf 'noise\\n' >&2")

        let negative = try await StreamingProcessRunner.run(executable: executable, arguments: [], timeout: 3, stdoutCap: -1, stderrCap: 16) { _ in }
        let exact = try await StreamingProcessRunner.run(executable: executable, arguments: [], timeout: 3, stdoutCap: 3, stderrCap: 16) { _ in }
        let exceeded = try await StreamingProcessRunner.run(executable: executable, arguments: [], timeout: 3, stdoutCap: 9, stderrCap: 16) { _ in }

        XCTAssertTrue(negative.stdout.isEmpty)
        XCTAssertEqual(String(decoding: exact.stdout, as: UTF8.self), "abc")
        XCTAssertEqual(String(decoding: exceeded.stdout, as: UTF8.self), "abcdef")
    }

    func testTimeoutReapsFixtureChild() async throws {
        let fixture = try Fixture()
        let pid = fixture.url.appendingPathComponent("pid")
        let executable = try fixture.script("echo $$ > '\(pid.path)'; while :; do sleep 1; done")

        let task = Task<Result<StreamingProcessResult, Error>, Never> {
            do { return .success(try await StreamingProcessRunner.run(executable: executable, arguments: [], timeout: 1, stdoutCap: 0, stderrCap: 0) { _ in }) }
            catch { return .failure(error) }
        }
        try await waitForFile(pid)
        let result = await task.value
        assertRunnerError(result, .timedOut)
        XCTAssertFalse(try processExists(pid))
    }

    func testCallingTaskCancellationReapsFixtureChild() async throws {
        let fixture = try Fixture()
        let pid = fixture.url.appendingPathComponent("pid")
        let executable = try fixture.script("echo $$ > '\(pid.path)'; while :; do sleep 1; done")
        let task = Task<Result<StreamingProcessResult, Error>, Never> {
            do { return .success(try await StreamingProcessRunner.run(executable: executable, arguments: [], timeout: 10, stdoutCap: 0, stderrCap: 0) { _ in }) }
            catch { return .failure(error) }
        }
        try await waitForFile(pid)
        task.cancel()
        let result = await task.value
        assertRunnerError(result, .cancelled)
        XCTAssertFalse(try processExists(pid))
    }

    func testLaunchFailureIsStatic() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await XCTAssertRunnerError(try await StreamingProcessRunner.run(executable: missing, arguments: [], timeout: 1, stdoutCap: 0, stderrCap: 0) { _ in }, .processFailed)
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Fixture did not publish its PID")
    }

    private func processExists(_ pidFile: URL) throws -> Bool {
        let pid = Int32(try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))!
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

private final class Fixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("lustre-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func script(_ body: String) throws -> URL {
        let script = url.appendingPathComponent("fixture-\(UUID().uuidString)")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}

private actor ProgressRecorder {
    private var samples: [Int64] = []
    func record(_ bytes: Int64) { samples.append(bytes) }
    func values() -> [Int64] { samples }
}

private actor CallbackGate {
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { waiter = $0 }
        }, onCancel: {
            Task { await self.release() }
        })
    }

    func isWaiting() -> Bool { waiter != nil }

    func release() {
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume()
    }
}

private func XCTAssertRunnerError<T>(_ expression: @autoclosure () async throws -> T, _ expected: StreamingProcessRunnerError, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? StreamingProcessRunnerError, expected, file: file, line: line) }
}

private func assertRunnerError(_ result: Result<StreamingProcessResult, Error>, _ expected: StreamingProcessRunnerError, file: StaticString = #filePath, line: UInt = #line) {
    switch result {
    case .success: XCTFail("Expected \(expected)", file: file, line: line)
    case .failure(let error): XCTAssertEqual(error as? StreamingProcessRunnerError, expected, file: file, line: line)
    }
}
