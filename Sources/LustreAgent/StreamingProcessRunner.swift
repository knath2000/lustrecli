import Foundation
import Darwin

enum StreamingProcessRunnerError: Error, Equatable { case timedOut, cancelled, processFailed, streamFailed }

struct StreamingProcessResult: Sendable { let status: Int32; let stdout: Data; let stderrDiagnostics: Data }

enum StreamingProcessRunner {
    static func run(executable: URL, arguments: [String], timeout: TimeInterval, stdoutCap: Int, stderrCap: Int, onProgress: @escaping @Sendable (YtDlpProgressSample) async -> Void) async throws -> StreamingProcessResult {
        let stdoutCap = max(0, stdoutCap)
        let stderrCap = max(0, stderrCap)
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutStream = stream(stdout.fileHandleForReading)
        let stderrStream = stream(stderr.fileHandleForReading)
        try process.run()
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            stdout.fileHandleForReading.closeFile()
            stderr.fileHandleForReading.closeFile()
        }
        do {
            return try await withTaskCancellationHandler(operation: {
                try await withThrowingTaskGroup(of: StreamingProcessResult.self) { group in
                    group.addTask {
                        async let out = retain(stdoutStream, cap: stdoutCap)
                        async let err = diagnostics(stderrStream, cap: stderrCap, onProgress: onProgress)
                        process.waitUntilExit()
                        return StreamingProcessResult(status: process.terminationStatus, stdout: try await out, stderrDiagnostics: try await err)
                    }
                    group.addTask { try await Task.sleep(for: .seconds(timeout)); throw StreamingProcessRunnerError.timedOut }
                    defer { group.cancelAll(); terminate(process) }
                    guard let result = try await group.next() else { throw StreamingProcessRunnerError.processFailed }
                    return result
                }
            }, onCancel: { terminate(process) })
        } catch is CancellationError { terminate(process); throw StreamingProcessRunnerError.cancelled }
        catch { terminate(process); throw error }
    }

    private static func stream(_ handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    private static func retain(_ stream: AsyncStream<Data>, cap: Int) async throws -> Data {
        var result = Data()
        for await data in stream {
            if result.count < cap { result.append(data.prefix(cap - result.count)) }
        }
        return result
    }

    private static func diagnostics(_ stream: AsyncStream<Data>, cap: Int, onProgress: @escaping @Sendable (YtDlpProgressSample) async -> Void) async throws -> Data {
        var decoder = BoundedLineDecoder(maximumLineBytes: 1024)
        var diagnostics = Data()
        func consume(_ lines: [Data]) async {
            for line in lines {
                if let sample = try? YtDlpProgressParser.parse(line) { await onProgress(sample) }
                else if diagnostics.count < cap {
                    let remaining = cap - diagnostics.count
                    let payload = line.prefix(max(0, remaining - 1))
                    diagnostics.append(payload)
                    if diagnostics.count < cap { diagnostics.append(10) }
                }
            }
        }
        for await data in stream { await consume(try decoder.append(data)) }
        await consume(try decoder.finish())
        return diagnostics
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<10 where process.isRunning { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        if process.isRunning { process.waitUntilExit() }
    }
}
