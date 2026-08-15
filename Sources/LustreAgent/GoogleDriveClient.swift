import Foundation
import LustreCore

enum GoogleDriveClientError: Error, LocalizedError {
    case rcloneUnavailable
    case remoteUnavailable
    case commandFailed(String)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .rcloneUnavailable: "rclone is not installed on the paired Mac."
        case .remoteUnavailable: "Google Drive is not connected in rclone on the paired Mac."
        case .commandFailed(let message): message
        case .verificationFailed: "Google Drive did not report the uploaded file after transfer."
        }
    }
}

struct GoogleDriveClient: Sendable {
    private struct RemoteEntry: Decodable {
        let Name: String
        let Path: String?
        let Size: Int64?
        let IsDir: Bool
    }

    private struct RcloneLogEntry: Decodable {
        struct Stats: Decodable {
            let bytes: Int64
            let totalBytes: Int64?
            let speed: Double?
            let eta: Double?
        }

        let stats: Stats?
    }

    func configuredDriveRemotes() async throws -> [String] {
        let result = try await run(["config", "dump"], timeout: 10)
        guard result.status == 0,
              let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: [String: Any]] else {
            throw GoogleDriveClientError.commandFailed(cleaned(result))
        }
        return object.compactMap { name, configuration in
            (configuration["type"] as? String) == "drive" ? name : nil
        }.sorted()
    }

    func folders(remoteName: String, path: String) async throws -> [GoogleDriveFolder] {
        let destination = rclonePath(remoteName: remoteName, path: path)
        let result = try await run(["lsjson", destination, "--dirs-only", "--max-depth", "1", "--no-mimetype", "--no-modtime"], timeout: 30)
        guard result.status == 0 else { throw GoogleDriveClientError.commandFailed(cleaned(result)) }
        let entries = try JSONDecoder().decode([RemoteEntry].self, from: Data(result.stdout.utf8))
        let parent = normalizedPath(path)
        return entries.filter(\.IsDir).map {
            let child = $0.Path ?? $0.Name
            return GoogleDriveFolder(name: $0.Name, path: parent == "/" ? "/\(child)" : "\(parent)/\(child)")
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func createFolder(remoteName: String, path: String) async throws {
        let result = try await run(["mkdir", rclonePath(remoteName: remoteName, path: path)], timeout: 30)
        guard result.status == 0 else { throw GoogleDriveClientError.commandFailed(cleaned(result)) }
    }

    func test(profile: GoogleDriveDestinationProfile) async throws -> RemoteDestinationTestResult {
        let result = try await run(["lsjson", rclonePath(remoteName: profile.remoteName, path: profile.remotePath), "--max-depth", "1", "--dirs-only", "--no-mimetype", "--no-modtime"], timeout: 30)
        guard result.status == 0 else { throw GoogleDriveClientError.commandFailed(cleaned(result)) }
        return RemoteDestinationTestResult(message: "Google Drive connection succeeded.")
    }

    func upload(file: URL, profile: GoogleDriveDestinationProfile, onProgress: @escaping @Sendable (DownloadProgress) async -> Void) async throws -> URL {
        let size = Int64((try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        await onProgress(DownloadProgress(bytesWritten: 0, totalBytes: size, phase: .uploading))
        let destinationPath = profile.remotePath == "/" ? "/\(file.lastPathComponent)" : "\(profile.remotePath)/\(file.lastPathComponent)"
        let destination = rclonePath(remoteName: profile.remoteName, path: destinationPath)
        var lastFailure = ""
        for delay in [0, 15, 45] {
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
            let result = try await runUpload(
                ["copyto", file.path, destination, "--transfers", "1", "--fast-list", "--stats", "1s", "--stats-one-line", "--use-json-log", "--log-level", "INFO"],
                expectedSize: size,
                timeout: 7_200,
                onProgress: onProgress
            )
            if result.status == 0 {
                await onProgress(DownloadProgress(bytesWritten: size, totalBytes: size, phase: .verifying))
                let verified = try await verify(destination: destination, expectedSize: size)
                guard verified else { throw GoogleDriveClientError.verificationFailed }
                return URL(string: "https://drive.google.com/drive/my-drive")!
            }
            lastFailure = cleaned(result)
            if !isQuotaFailure(lastFailure) { break }
            if try await verify(destination: destination, expectedSize: size) {
                return URL(string: "https://drive.google.com/drive/my-drive")!
            }
        }
        throw GoogleDriveClientError.commandFailed(isQuotaFailure(lastFailure) ? "Google Drive rate limit persisted after two retries. \(lastFailure)" : lastFailure)
    }

    private func verify(destination: String, expectedSize: Int64) async throws -> Bool {
        let result = try await run(["lsjson", destination, "--stat", "--files-only", "--no-mimetype", "--no-modtime"], timeout: 30)
        guard result.status == 0,
              let entry = try? JSONDecoder().decode(RemoteEntry.self, from: Data(result.stdout.utf8)),
              entry.IsDir == false else { return false }
        return expectedSize > 0 ? entry.Size == expectedSize : (entry.Size ?? 0) > 0
    }

    private func rclonePath(remoteName: String, path: String) -> String {
        let normalized = normalizedPath(path)
        return normalized == "/" ? "\(remoteName):" : "\(remoteName):\(normalized.dropFirst())"
    }

    private func normalizedPath(_ value: String) -> String {
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private func isQuotaFailure(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("quota exceeded") || value.contains("rate limit") || value.contains("rate_limit_exceeded")
    }

    private func cleaned(_ result: (status: Int32, stdout: String, stderr: String)) -> String {
        let value = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : value
    }

    private func runUpload(_ arguments: [String], expectedSize: Int64, timeout: TimeInterval, onProgress: @escaping @Sendable (DownloadProgress) async -> Void) async throws -> (status: Int32, stdout: String, stderr: String) {
        guard let executable = ["/usr/local/bin/rclone", "/opt/homebrew/bin/rclone"].first(where: FileManager.default.isExecutableFile) else {
            throw GoogleDriveClientError.rcloneUnavailable
        }
        let logURL = FileManager.default.temporaryDirectory.appending(path: "lustre-rclone-\(UUID().uuidString).jsonl")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
            throw GoogleDriveClientError.commandFailed("Unable to create the rclone progress log.")
        }
        let writer = try FileHandle(forWritingTo: logURL)
        let reader = try FileHandle(forReadingFrom: logURL)
        defer {
            writer.closeFile()
            reader.closeFile()
            try? FileManager.default.removeItem(at: logURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = writer
        try process.run()

        var pending = Data()
        var diagnostics = Data()
        func consumeAvailable() async {
            let next = reader.readDataToEndOfFile()
            guard !next.isEmpty else { return }
            if diagnostics.count < 65_536 {
                diagnostics.append(next.prefix(65_536 - diagnostics.count))
            }
            pending.append(next)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                if let progress = Self.rcloneProgress(Data(line), expectedSize: expectedSize) {
                    await onProgress(progress)
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                if Task.isCancelled { throw CancellationError() }
                if Date() >= deadline { throw GoogleDriveClientError.commandFailed("rclone timed out.") }
                await consumeAvailable()
                try await Task.sleep(for: .milliseconds(250))
            }
            process.waitUntilExit()
            await consumeAvailable()
        } catch {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            throw error
        }
        return (process.terminationStatus, "", String(decoding: diagnostics, as: UTF8.self))
    }

    static func rcloneProgress(_ line: Data, expectedSize: Int64) -> DownloadProgress? {
        guard expectedSize > 0,
              let stats = try? JSONDecoder().decode(RcloneLogEntry.self, from: line).stats
        else { return nil }
        let bytes = min(max(0, stats.bytes), expectedSize)
        let eta = stats.eta.flatMap { $0.isFinite && $0 >= 0 ? Int($0.rounded(.up)) : nil }
        return DownloadProgress(
            bytesWritten: bytes,
            totalBytes: expectedSize,
            phase: .uploading,
            bytesPerSecond: stats.speed,
            etaSeconds: eta
        )
    }

    private func run(_ arguments: [String], timeout: TimeInterval) async throws -> (status: Int32, stdout: String, stderr: String) {
        guard let executable = ["/usr/local/bin/rclone", "/opt/homebrew/bin/rclone"].first(where: FileManager.default.isExecutableFile) else {
            throw GoogleDriveClientError.rcloneUnavailable
        }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                if Task.isCancelled {
                    process.terminate()
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
                throw GoogleDriveClientError.commandFailed("rclone timed out.")
            }
            return (
                process.terminationStatus,
                String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        }.value
    }
}
