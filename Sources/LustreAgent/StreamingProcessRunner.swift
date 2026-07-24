import Foundation
import Darwin

enum StreamingProcessRunnerError: Error, Equatable { case timedOut, cancelled, processFailed, streamFailed }

struct StreamingProcessResult: Sendable { let status: Int32; let stdout: Data; let stderrDiagnostics: Data }

enum StreamingProcessRunner {
    private static let chunkSize = 16 * 1024
    private static let progressCapacity = 8

    static func run(executable: URL, arguments: [String], timeout: TimeInterval, stdoutCap: Int, stderrCap: Int, onProgress: @escaping @Sendable (YtDlpProgressSample) async -> Void) async throws -> StreamingProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let lifecycle = RunnerLifecycle(process: process, stdout: stdout.fileHandleForReading, stderr: stderr.fileHandleForReading)
        let channel = YtDlpProgressEventChannel(capacity: progressCapacity)
        let consumer = Task.detached {
            do { while let sample = try await channel.next() { await onProgress(sample) } }
            catch {}
        }
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() }
        catch {
            lifecycle.closeReads()
            await channel.cancel()
            consumer.cancel()
            _ = await consumer.value
            throw StreamingProcessRunnerError.processFailed
        }

        let stdoutTask = Task.detached { try await readStdout(stdout.fileHandleForReading, cap: max(0, stdoutCap), lifecycle: lifecycle) }
        let stderrTask = Task.detached { try await readStderr(stderr.fileHandleForReading, cap: max(0, stderrCap), channel: channel, lifecycle: lifecycle) }
        let waitTask = Task.detached { lifecycle.waitForExit() }
        let timeoutTask = Task.detached {
            guard timeout.isFinite, timeout > 0 else {
                await abort(.timedOut, lifecycle: lifecycle, channel: channel, consumer: consumer)
                return
            }
            do { try await Task.sleep(for: .seconds(timeout)) }
            catch { return }
            await abort(.timedOut, lifecycle: lifecycle, channel: channel, consumer: consumer)
        }

        func join(abortive: Bool) async {
            if abortive { lifecycle.closeReads() }
            _ = try? await stderrTask.value
            _ = try? await stdoutTask.value
            _ = await waitTask.value
            consumer.cancel()
            _ = await consumer.value
            timeoutTask.cancel()
            _ = await timeoutTask.value
        }

        do {
            let result = try await withTaskCancellationHandler(operation: {
                let diagnostics = try await stderrTask.value
                let status = await waitTask.value
                let output = try await stdoutTask.value
                await channel.finish()
                await consumer.value
                guard lifecycle.claim(.succeeded) else { throw lifecycle.error }
                timeoutTask.cancel()
                _ = await timeoutTask.value
                lifecycle.closeReads()
                return StreamingProcessResult(status: status, stdout: output, stderrDiagnostics: diagnostics)
            }, onCancel: {
                guard lifecycle.claim(.cancelled) else { return }
                Task { await abortClaimed(lifecycle: lifecycle, channel: channel, consumer: consumer) }
            })
            return result
        } catch is CancellationError {
            await abort(.cancelled, lifecycle: lifecycle, channel: channel, consumer: consumer)
            await join(abortive: true)
            throw StreamingProcessRunnerError.cancelled
        } catch let error as StreamingProcessRunnerError {
            await abort(error == .timedOut ? .timedOut : error == .cancelled ? .cancelled : .streamFailed, lifecycle: lifecycle, channel: channel, consumer: consumer)
            await join(abortive: true)
            throw lifecycle.error
        } catch {
            await abort(.streamFailed, lifecycle: lifecycle, channel: channel, consumer: consumer)
            await join(abortive: true)
            throw lifecycle.error
        }
    }

    private static func abort(_ outcome: RunnerOutcome, lifecycle: RunnerLifecycle, channel: YtDlpProgressEventChannel, consumer: Task<Void, Never>) async {
        guard lifecycle.claim(outcome) else { return }
        await abortClaimed(lifecycle: lifecycle, channel: channel, consumer: consumer)
    }

    private static func abortClaimed(lifecycle: RunnerLifecycle, channel: YtDlpProgressEventChannel, consumer: Task<Void, Never>) async {
        lifecycle.terminate()
        lifecycle.closeReads()
        await channel.cancel()
        consumer.cancel()
    }

    private static func readStdout(_ handle: FileHandle, cap: Int, lifecycle: RunnerLifecycle) async throws -> Data {
        var retained = Data()
        while let chunk = try readChunk(handle, lifecycle: lifecycle) {
            if retained.count < cap { retained.append(chunk.prefix(cap - retained.count)) }
        }
        return retained
    }

    private static func readStderr(_ handle: FileHandle, cap: Int, channel: YtDlpProgressEventChannel, lifecycle: RunnerLifecycle) async throws -> Data {
        var decoder = BoundedLineDecoder(maximumLineBytes: 1024)
        var diagnostics = Data()
        func consume(_ lines: [Data]) async throws {
            for line in lines {
                do { try await channel.offer(YtDlpProgressParser.parse(line)) }
                catch YtDlpProgressEventChannelError.capacityExceeded { throw StreamingProcessRunnerError.streamFailed }
                catch YtDlpProgressEventChannelError.closed, YtDlpProgressEventChannelError.cancelled, YtDlpProgressEventChannelError.multipleConsumers {
                    if lifecycle.isAbortive { return }
                    throw StreamingProcessRunnerError.streamFailed
                } catch { appendDiagnostic(line, to: &diagnostics, cap: cap) }
            }
        }
        while let chunk = try readChunk(handle, lifecycle: lifecycle) { try await consume(try decoder.append(chunk)) }
        if lifecycle.isAbortive { return diagnostics }
        try await consume(try decoder.finish())
        return diagnostics
    }

    private static func readChunk(_ handle: FileHandle, lifecycle: RunnerLifecycle) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: chunkSize)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EBADF && lifecycle.isAbortive { return nil }
            if errno == EINTR { return try readChunk(handle, lifecycle: lifecycle) }
            throw StreamingProcessRunnerError.streamFailed
        }
        return count == 0 ? nil : Data(bytes[0..<Int(count)])
    }

    private static func appendDiagnostic(_ line: Data, to diagnostics: inout Data, cap: Int) {
        guard diagnostics.count < cap else { return }
        let remaining = cap - diagnostics.count
        diagnostics.append(line.prefix(max(0, remaining - 1)))
        if diagnostics.count < cap { diagnostics.append(10) }
    }
}

private enum RunnerOutcome { case running, succeeded, timedOut, cancelled, streamFailed }

private final class RunnerLifecycle: @unchecked Sendable {
    private let process: Process
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let lock = NSLock()
    private var outcome: RunnerOutcome = .running
    private var readsClosed = false
    private var terminating = false

    init(process: Process, stdout: FileHandle, stderr: FileHandle) { self.process = process; self.stdout = stdout; self.stderr = stderr }

    var isAbortive: Bool { lock.lock(); defer { lock.unlock() }; return outcome != .running && outcome != .succeeded }
    var error: StreamingProcessRunnerError {
        lock.lock(); defer { lock.unlock() }
        switch outcome { case .timedOut: return .timedOut; case .cancelled: return .cancelled; default: return .streamFailed }
    }

    func claim(_ candidate: RunnerOutcome) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard outcome == .running else { return false }
        outcome = candidate
        return true
    }

    func closeReads() {
        lock.lock()
        guard !readsClosed else { lock.unlock(); return }
        readsClosed = true
        lock.unlock()
        stdout.closeFile()
        stderr.closeFile()
    }

    func terminate() {
        lock.lock()
        guard !terminating, process.isRunning else { lock.unlock(); return }
        terminating = true
        lock.unlock()
        process.terminate()
        for _ in 0..<10 where process.isRunning { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func waitForExit() -> Int32 { process.waitUntilExit(); return process.terminationStatus }
}
