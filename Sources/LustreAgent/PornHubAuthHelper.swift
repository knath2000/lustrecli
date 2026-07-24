import Foundation
import Darwin

public struct PornHubAuthHelper: PornHubAuthHelping {
    public static let executableName = "lustre-auth-helper"
    private let executableURL: URL?
    private let timeout: TimeInterval

    public init(executableURL: URL? = nil, timeout: TimeInterval = 15 * 60) {
        self.executableURL = executableURL; self.timeout = timeout
    }

    public func login() async throws -> PornHubHelperResult { try await run(argument: "login") }
    public func logout() async throws { _ = try await run(argument: "logout") }

    public static func validatedExecutable(runningAgent: URL) throws -> URL {
        let agent = runningAgent.resolvingSymlinksInPath().standardizedFileURL
        let candidate = agent.deletingLastPathComponent().appendingPathComponent(executableName)
        guard candidate.lastPathComponent == executableName,
              FileManager.default.fileExists(atPath: candidate.path),
              FileManager.default.isExecutableFile(atPath: candidate.path),
              (try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isRegularFile == true,
              (try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isSymbolicLink != true else {
            throw PornHubAuthError.helperUnavailable
        }
        return candidate.resolvingSymlinksInPath().standardizedFileURL
    }

    private func run(argument: String) async throws -> PornHubHelperResult {
        let current = executableURL ?? Bundle.main.executableURL
        guard let current else { throw PornHubAuthError.helperUnavailable }
        let executable = try Self.validatedExecutable(runningAgent: current)
        let process = Process()
        let stdout = Pipe(); let stderr = Pipe()
        process.executableURL = executable
        process.arguments = [argument]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output: ProcessOutput
        do {
            output = try await wait(process: process, stdout: stdout.fileHandleForReading, stderr: stderr.fileHandleForReading)
        } catch {
            terminateAndWait(process)
            throw error
        }
        guard output.status == 0, output.stdout.count <= 64,
              let token = String(data: output.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { throw PornHubAuthError.helperFailed }
        switch token {
        case "signed-in": return .signedIn
        case "cancelled": return .cancelled
        case "signed-out": return .signedOut
        case "storage-unavailable": throw PornHubAuthError.storageUnavailable
        case "helper-failed": throw PornHubAuthError.helperFailed
        default: throw PornHubAuthError.helperFailed
        }
    }

    private struct ProcessOutput: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    private enum ProcessEvent: Sendable {
        case stdout(Data)
        case stderr(Data)
        case exited(Int32)
    }

    private func wait(process: Process, stdout: FileHandle, stderr: FileHandle) async throws -> ProcessOutput {
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: ProcessOutput.self) { group in
                    group.addTask {
                        var output = Data()
                        var diagnostics = Data()
                        var status: Int32?
                        try await withThrowingTaskGroup(of: ProcessEvent.self) { events in
                            defer {
                                events.cancelAll()
                                terminateAndWait(process)
                            }
                            events.addTask { .stdout(try await readCapped(stdout, cap: 64)) }
                            events.addTask { .stderr(try await readCapped(stderr, cap: 256)) }
                            events.addTask { process.waitUntilExit(); return .exited(process.terminationStatus) }
                            for try await event in events {
                                switch event {
                                case .stdout(let data): output = data
                                case .stderr(let data): diagnostics = data
                                case .exited(let value): status = value
                                }
                            }
                        }
                        guard let status else { throw PornHubAuthError.helperFailed }
                        return ProcessOutput(status: status, stdout: output, stderr: diagnostics)
                    }
                    group.addTask { try await Task.sleep(for: .seconds(timeout)); throw PornHubAuthError.timeout }
                    defer {
                        group.cancelAll()
                        terminateAndWait(process)
                    }
                    guard let value = try await group.next() else { throw PornHubAuthError.helperFailed }
                    return value
                }
            } onCancel: {
                terminateAndWait(process)
            }
        } catch is CancellationError {
            terminateAndWait(process)
            throw PornHubAuthError.cancelled
        } catch {
            terminateAndWait(process)
            throw error
        }
    }

    private func readCapped(_ handle: FileHandle, cap: Int) async throws -> Data {
        var output = Data()
        while true {
            let data = try handle.read(upToCount: min(64, cap - output.count + 1)) ?? Data()
            if data.isEmpty { return output }
            output.append(data)
            guard output.count <= cap else { throw PornHubAuthError.helperFailed }
        }
    }

    private func terminateAndWait(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<20 where process.isRunning {
            usleep(100_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        if process.isRunning { process.waitUntilExit() }
    }
}
