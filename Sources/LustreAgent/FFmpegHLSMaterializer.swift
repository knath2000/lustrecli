import Foundation
import LustreCore
import Darwin

enum FFmpegHLSMaterializer {
    static func materialize(
        resolution: ProviderResolution,
        quality: ResolvedQuality,
        directory: URL,
        onProgress: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws -> URL {
        guard quality.mediaKind == .hls, URLSafetyPolicy.isAllowed(quality.url) else {
            throw HLSMaterializationError.invalidURL
        }
        let executable = try ffmpegExecutable()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = sanitizedFilename(resolution.title ?? quality.url.deletingPathExtension().lastPathComponent)
        let destination = uniqueURL(directory.appendingPathComponent(filename).appendingPathExtension("mp4"))
        let partial = destination.appendingPathExtension("part")
        defer {
            if !FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: partial)
            }
        }

        let arguments = try arguments(for: quality, partial: partial)
        let status = try await runProcess(executable: executable, arguments: arguments)
        guard status == 0,
              (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 > 0 }) == true else {
            throw HLSMaterializationError.failed
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        let size = Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        await onProgress(DownloadProgress(bytesWritten: size, totalBytes: size))
        return destination
    }

    static func arguments(for quality: ResolvedQuality, partial: URL) throws -> [String] {
        guard quality.headers.allSatisfy({
            $0.key.rangeOfCharacter(from: .newlines) == nil
                && $0.value.rangeOfCharacter(from: .newlines) == nil
        }) else {
            throw HLSMaterializationError.invalidHeaders
        }
        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error"]
        let headerLines = quality.headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
        if !headerLines.isEmpty {
            arguments += ["-headers", headerLines.joined(separator: "\r\n") + "\r\n"]
        }
        arguments += [
            "-i", quality.url.absoluteString, "-map", "0", "-c", "copy",
            "-movflags", "+faststart", "-f", "mp4", partial.path
        ]
        return arguments
    }

    static func runProcess(executable: URL, arguments: [String], timeout: TimeInterval = 7_200) async throws -> Int32 {
        let process = Process()
        let errorPipe = Pipe()
        let capture = BoundedProcessOutput(limit: 16_384)
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            capture.append(handle.availableData)
        }
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Task.isCancelled {
                    terminate(process)
                    throw CancellationError()
                }
                if Date() >= deadline {
                    terminate(process)
                    throw HLSMaterializationError.timedOut
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            errorPipe.fileHandleForReading.readabilityHandler = nil
            capture.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            return process.terminationStatus
        } catch {
            if process.isRunning { terminate(process) }
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    private static func terminate(_ process: Process) {
        process.terminate()
        let terminateDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < terminateDeadline {
            usleep(20_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline {
                usleep(20_000)
            }
        }
    }

    private static func ffmpegExecutable() throws -> URL {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw HLSMaterializationError.ffmpegMissing
    }

    private static func sanitizedFilename(_ raw: String) -> String {
        let value = raw.replacingOccurrences(of: #"[^A-Za-z0-9._ -]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Lustre Video" : String(value.prefix(160))
    }

    private static func uniqueURL(_ preferred: URL) -> URL {
        guard FileManager.default.fileExists(atPath: preferred.path) else { return preferred }
        for number in 2...10_000 {
            let candidate = preferred.deletingPathExtension()
                .appendingPathExtension(String(number))
                .appendingPathExtension(preferred.pathExtension)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return preferred.deletingPathExtension().appendingPathExtension(UUID().uuidString).appendingPathExtension(preferred.pathExtension)
    }
}

enum HLSMaterializationError: Error, LocalizedError {
    case invalidURL
    case invalidHeaders
    case ffmpegMissing
    case timedOut
    case failed

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The HLS playlist URL is not safe to fetch."
        case .invalidHeaders: "HLS request headers contain an invalid line break."
        case .ffmpegMissing: "HLS downloads require ffmpeg. Install it at /opt/homebrew/bin/ffmpeg, /usr/local/bin/ffmpeg, /opt/local/bin/ffmpeg, or /usr/bin/ffmpeg."
        case .timedOut: "ffmpeg exceeded the two-hour HLS materialization limit."
        case .failed: "ffmpeg could not materialize the HLS stream as MP4."
        }
    }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if data.count < limit {
            data.append(newData.prefix(limit - data.count))
        }
    }
}
