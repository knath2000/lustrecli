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
        let estimatedDuration = await playlistDuration(for: quality)
        var status: Int32 = -1
        for attempt in 1...3 {
            if attempt > 1 {
                try? FileManager.default.removeItem(at: partial)
            }
            do {
                status = try await runProcess(executable: executable, arguments: arguments, estimatedDuration: estimatedDuration, onProgress: onProgress)
                if status == 0 { break }
            } catch HLSMaterializationError.stalled where attempt < 3 {
                continue
            } catch {
                throw error
            }
        }
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
        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
        let headerLines = quality.headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
        if !headerLines.isEmpty {
            arguments += ["-headers", headerLines.joined(separator: "\r\n") + "\r\n"]
        }
        arguments += [
            "-rw_timeout", "30000000", "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "10", "-reconnect_max_retries", "5", "-reconnect_delay_total_max", "30",
            "-i", quality.url.absoluteString, "-map", "0", "-c", "copy",
            "-f", "mp4", partial.path
        ]
        return arguments
    }

    static func runProcess(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 7_200,
        stallTimeout: TimeInterval = 90,
        estimatedDuration: TimeInterval? = nil,
        onProgress: (@Sendable (DownloadProgress) async -> Void)? = nil
    ) async throws -> Int32 {
        let process = Process()
        let errorPipe = Pipe()
        let capture = BoundedProcessOutput(limit: 16_384)
        let progressPipe = onProgress == nil ? nil : Pipe()
        let progressCapture = FFmpegProgressCapture(estimatedDuration: estimatedDuration, onProgress: onProgress)
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            capture.append(handle.availableData)
        }
        progressPipe?.fileHandleForReading.readabilityHandler = { handle in
            progressCapture.append(handle.availableData)
        }
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = progressPipe ?? FileHandle.nullDevice
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
                if onProgress != nil, progressCapture.hasStalled(for: stallTimeout) {
                    terminate(process)
                    throw HLSMaterializationError.stalled
                }
                if progressCapture.hasPostProcessingTimedOut(for: 900) {
                    terminate(process)
                    throw HLSMaterializationError.postProcessingTimedOut
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            errorPipe.fileHandleForReading.readabilityHandler = nil
            progressPipe?.fileHandleForReading.readabilityHandler = nil
            capture.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            if let progressPipe {
                progressCapture.append(progressPipe.fileHandleForReading.readDataToEndOfFile())
            }
            return process.terminationStatus
        } catch {
            if process.isRunning { terminate(process) }
            errorPipe.fileHandleForReading.readabilityHandler = nil
            progressPipe?.fileHandleForReading.readabilityHandler = nil
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

    private static func playlistDuration(for quality: ResolvedQuality) async -> TimeInterval? {
        var request = URLRequest(url: quality.url)
        request.timeoutInterval = 15
        quality.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              data.count <= 2_000_000,
              let playlist = String(data: data, encoding: .utf8)
        else { return nil }
        let duration = playlist.split(whereSeparator: \.isNewline).reduce(0.0) { result, line in
            guard line.hasPrefix("#EXTINF:"),
                  let value = Double(line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1)[0])
            else { return result }
            return result + value
        }
        return duration > 0 ? duration : nil
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
    case stalled
    case postProcessingTimedOut
    case failed

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The HLS playlist URL is not safe to fetch."
        case .invalidHeaders: "HLS request headers contain an invalid line break."
        case .ffmpegMissing: "HLS downloads require ffmpeg. Install it at /opt/homebrew/bin/ffmpeg, /usr/local/bin/ffmpeg, /opt/local/bin/ffmpeg, or /usr/bin/ffmpeg."
        case .timedOut: "ffmpeg exceeded the two-hour HLS materialization limit."
        case .stalled: "The HLS stream stopped delivering data after three attempts."
        case .postProcessingTimedOut: "ffmpeg could not finish the MP4 after downloading the media."
        case .failed: "ffmpeg could not materialize the HLS stream as MP4."
        }
    }
}

private final class FFmpegProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let estimatedDuration: TimeInterval?
    private let onProgress: (@Sendable (DownloadProgress) async -> Void)?
    private var buffer = Data()
    private var lastBytes: Int64 = 0
    private var currentBytes: Int64 = 0
    private var outputSeconds: TimeInterval = 0
    private var lastAdvanceAt = Date()
    private var lastReportAt = Date()
    private var nearCompletionAt: Date?

    init(estimatedDuration: TimeInterval?, onProgress: (@Sendable (DownloadProgress) async -> Void)?) {
        self.estimatedDuration = estimatedDuration
        self.onProgress = onProgress
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if line.hasPrefix("total_size="), let bytes = Int64(line.dropFirst("total_size=".count)), bytes >= lastBytes {
                currentBytes = bytes
            } else if line.hasPrefix("out_time_us="), let microseconds = Double(line.dropFirst("out_time_us=".count)) {
                outputSeconds = max(0, microseconds / 1_000_000)
            } else if line.hasPrefix("progress=") {
                let now = Date()
                let elapsed = max(now.timeIntervalSince(lastReportAt), 0.001)
                let rate = currentBytes > lastBytes ? Double(currentBytes - lastBytes) / elapsed : nil
                if currentBytes > lastBytes {
                    lastBytes = currentBytes
                    lastAdvanceAt = now
                }
                lastReportAt = now
                let fraction = estimatedDuration.map { min(max(outputSeconds / $0, 0), 1) }
                if fraction.map({ $0 >= 0.995 }) == true, nearCompletionAt == nil {
                    nearCompletionAt = now
                }
                let estimatedTotal = fraction.flatMap { $0 > 0 ? Int64(Double(currentBytes) / $0) : nil }
                let eta = estimatedDuration.map { max(0, Int(($0 - outputSeconds).rounded())) }
                if let onProgress {
                    let bytes = currentBytes
                    let phase: TransferPhase = fraction.map { $0 >= 0.995 ? .postProcessing : .materializing } ?? .materializing
                    Task { await onProgress(DownloadProgress(bytesWritten: bytes, totalBytes: estimatedTotal, phase: phase, totalIsEstimated: estimatedTotal != nil, bytesPerSecond: rate, etaSeconds: eta)) }
                }
            }
        }
        lock.unlock()
    }

    func hasStalled(for interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let estimatedDuration, estimatedDuration > 0, outputSeconds / estimatedDuration >= 0.995 {
            return false
        }
        return Date().timeIntervalSince(lastAdvanceAt) >= interval
    }

    func hasPostProcessingTimedOut(for interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let nearCompletionAt else { return false }
        return Date().timeIntervalSince(nearCompletionAt) >= interval
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
