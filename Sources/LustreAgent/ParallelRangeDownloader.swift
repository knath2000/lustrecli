import Foundation
import LustreCore

public struct ParallelRangeProgress: Sendable, Equatable {
    public let completedBytes: Int64
    public let totalBytes: Int64?
    public let rangesDone: Int
    public let rangesTotal: Int
}

public enum ParallelRangeDownloadError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case unexpectedContentType
    case responseTooSmall
    case rangeRejected
    case rangesUnsupported
    case ifRangeMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The media URL is not safe to fetch."
        case .invalidResponse: "The provider did not return a successful media response."
        case .unexpectedContentType: "The provider returned an HTML, JSON, or XML response instead of media."
        case .responseTooSmall: "The provider response was too small to be a media file."
        case .rangeRejected: "The provider rejected the requested byte range (HTTP 416)."
        case .rangesUnsupported: "The provider does not advertise support for parallel byte ranges."
        case .ifRangeMismatch: "If-Range mismatch; restarting from byte 0."
        }
    }
}

public struct ParallelRangeResult: Sendable {
    public let destination: URL
    public let resumeState: DownloadResumeState
}

public struct ParallelRangeRequest: Sendable {
    public let jobID: UUID
    public let sourcePageURL: URL
    public let title: String?
    public let mediaURL: URL
    public let headers: [String: String]
    public let destinationDirectory: URL
    public let destinationFilename: URL
    public let maxStreams: Int
    public let chunkSize: Int64
    public let resumeState: DownloadResumeState?
    public let onProgress: @Sendable (DownloadProgress) async -> Void
    public let onWorkerEvent: @Sendable (String) async -> Void

    public init(
        jobID: UUID,
        sourcePageURL: URL,
        title: String?,
        mediaURL: URL,
        headers: [String: String],
        destinationDirectory: URL,
        destinationFilename: URL,
        maxStreams: Int,
        chunkSize: Int64,
        resumeState: DownloadResumeState?,
        onProgress: @escaping @Sendable (DownloadProgress) async -> Void,
        onWorkerEvent: @escaping @Sendable (String) async -> Void
    ) {
        self.jobID = jobID
        self.sourcePageURL = sourcePageURL
        self.title = title
        self.mediaURL = mediaURL
        self.headers = headers
        self.destinationDirectory = destinationDirectory
        self.destinationFilename = destinationFilename
        self.maxStreams = max(1, min(maxStreams, 8))
        self.chunkSize = max(1_024 * 1_024, chunkSize)
        self.resumeState = resumeState
        self.onProgress = onProgress
        self.onWorkerEvent = onWorkerEvent
    }
}

public enum ParallelRangeDownloader {
    public static func download(_ request: ParallelRangeRequest) async throws -> ParallelRangeResult {
        if ProcessInfo.processInfo.environment["LUSTRE_TEST_SKIP_SAFETY"] != "1" {
            guard URLSafetyPolicy.isAllowed(request.mediaURL) else { throw ParallelRangeDownloadError.invalidURL }
        }
        try FileManager.default.createDirectory(at: request.destinationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: partialDirectory(for: request.jobID), withIntermediateDirectories: true)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.httpMaximumConnectionsPerHost = max(request.maxStreams, 4)
        let delegate = AgentDownloadRedirectDelegate()
        let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let probe = try await probeHead(session: session, request: request)
        try validateMediaResponse(probe.response)

        let total = probe.totalBytes
        let resume = request.resumeState
        let resumeValid = resume.flatMap { isResumeValid(state: $0, etag: probe.etag, lastModified: probe.lastModified, total: total) } ?? false
        let startingOffset: Int64 = resumeValid ? (resume?.byteOffset ?? 0) : 0

        if let total, startingOffset >= total {
            try await finalizeNoOpDownload(request: request, resumeState: resume)
            throw CancellationError.destinationAlreadyComplete
        }

        if let total, total < request.chunkSize {
            return try await singleStreamDownload(
                request: request,
                session: session,
                totalBytes: total,
                startingOffset: startingOffset,
                etag: probe.etag,
                lastModified: probe.lastModified
            )
        }

        let accepted = try await advertiseRangeSupport(session: session, request: request, totalBytes: total)
        guard accepted else {
            return try await singleStreamDownload(
                request: request,
                session: session,
                totalBytes: total,
                startingOffset: startingOffset,
                etag: probe.etag,
                lastModified: probe.lastModified
            )
        }

        let effectiveTotal = total ?? -1
        let plannedRanges = makeRanges(totalBytes: effectiveTotal, startingOffset: startingOffset, chunkSize: request.chunkSize, maxStreams: request.maxStreams)
        guard !plannedRanges.isEmpty else {
            return try await singleStreamDownload(
                request: request,
                session: session,
                totalBytes: total,
                startingOffset: startingOffset,
                etag: probe.etag,
                lastModified: probe.lastModified
            )
        }

        await request.onWorkerEvent("Range fan-out: \(plannedRanges.count) workers across \(formatRangeWindow(plannedRanges)).")

        let partialPath = partialFile(for: request)
        if startingOffset == 0 {
            FileManager.default.createFile(atPath: partialPath.path, contents: nil)
        }
        try ensureFileSize(at: partialPath, totalBytes: effectiveTotal > 0 ? Optional(effectiveTotal) : nil)

        let completedRangesBox = CompletedRangesBox(initial: resumeValid ? (resume?.rangesCompleted ?? []) : [])
        let totalBox = AtomicInt64(value: startingOffset)
        let reporter = ProgressReporter(request: request, total: total, totalBox: totalBox, completedRangesBox: completedRangesBox, plannedCount: plannedRanges.count)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for planned in plannedRanges {
                let workerSession = session
                group.addTask {
                    try await runRangeWorker(
                        session: workerSession,
                        request: request,
                        planned: planned,
                        totalBox: totalBox,
                        completedRangesBox: completedRangesBox,
                        reporter: reporter,
                        etag: probe.etag,
                        lastModified: probe.lastModified,
                        totalBytes: effectiveTotal > 0 ? effectiveTotal : nil
                    )
                }
            }
            try await group.waitForAll()
        }

        await reporter.finish()

        let finalResume = DownloadResumeState(
            byteOffset: total ?? totalBox.value,
            totalBytes: total,
            etag: probe.etag,
            lastModified: probe.lastModified,
            startedAt: resume?.startedAt ?? .now,
            rangesCompleted: completedRangesBox.snapshot()
        )
        let destination = request.destinationFilename
        try FileManager.default.moveItem(at: partialPath, to: destination)
        try? FileManager.default.removeItem(at: partialDirectory(for: request.jobID))
        return ParallelRangeResult(destination: destination, resumeState: finalResume)
    }

    public static func partialDirectory(for jobID: UUID) -> URL {
        AgentPaths.partialsDirectory.appending(path: jobID.uuidString, directoryHint: .isDirectory)
    }

    public static func partialFile(for request: ParallelRangeRequest) -> URL {
        partialDirectory(for: request.jobID).appending(path: request.destinationFilename.lastPathComponent + ".part")
    }

    public static func metadataFile(for request: ParallelRangeRequest) -> URL {
        partialDirectory(for: request.jobID).appending(path: request.destinationFilename.lastPathComponent + ".meta.json")
    }

    public static func removePartials(for jobID: UUID) {
        try? FileManager.default.removeItem(at: partialDirectory(for: jobID))
    }

    private static func probeHead(session: URLSession, request: ParallelRangeRequest) async throws -> (response: HTTPURLResponse, totalBytes: Int64?, etag: String?, lastModified: String?) {
        var headRequest = URLRequest(url: request.mediaURL)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 30
        applyHeaders(request.headers, to: &headRequest)
        let (_, response) = try await session.data(for: headRequest)
        guard let http = response as? HTTPURLResponse else { throw ParallelRangeDownloadError.invalidResponse }
        if ProcessInfo.processInfo.environment["LUSTRE_TEST_SKIP_SAFETY"] != "1" {
            guard URLSafetyPolicy.isAllowed(http.url ?? request.mediaURL) else { throw ParallelRangeDownloadError.invalidURL }
        }
        guard (200...299).contains(http.statusCode) else { throw ParallelRangeDownloadError.invalidResponse }
        let total = expectedBytes(from: http)
        let etag = http.value(forHTTPHeaderField: "ETag")
        let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        return (http, total, etag, lastModified)
    }

    private static func advertiseRangeSupport(session: URLSession, request: ParallelRangeRequest, totalBytes: Int64?) async throws -> Bool {
        var rangeRequest = URLRequest(url: request.mediaURL)
        rangeRequest.httpMethod = "GET"
        rangeRequest.timeoutInterval = 30
        applyHeaders(request.headers, to: &rangeRequest)
        rangeRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await session.data(for: rangeRequest)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 206
        } catch {
            return false
        }
    }

    private static func singleStreamDownload(
        request: ParallelRangeRequest,
        session: URLSession,
        totalBytes: Int64?,
        startingOffset: Int64,
        etag: String?,
        lastModified: String?
    ) async throws -> ParallelRangeResult {
        var downloadRequest = URLRequest(url: request.mediaURL)
        downloadRequest.httpMethod = "GET"
        downloadRequest.timeoutInterval = 600
        applyHeaders(request.headers, to: &downloadRequest)
        if startingOffset > 0 {
            downloadRequest.setValue("bytes=\(startingOffset)-", forHTTPHeaderField: "Range")
        }

        let partialPath = partialFile(for: request)
        if startingOffset == 0 {
            FileManager.default.createFile(atPath: partialPath.path, contents: nil)
        }
        if let totalBytes {
            try ensureFileSize(at: partialPath, totalBytes: totalBytes)
        }
        let handle = try FileHandle(forWritingTo: partialPath)
        defer { try? handle.close() }
        if startingOffset > 0 {
            try handle.seek(toOffset: UInt64(startingOffset))
        }

        let (bytes, response) = try await session.bytes(for: downloadRequest)
        guard let http = response as? HTTPURLResponse else { throw ParallelRangeDownloadError.invalidResponse }
        if ProcessInfo.processInfo.environment["LUSTRE_TEST_SKIP_SAFETY"] != "1" {
            guard URLSafetyPolicy.isAllowed(http.url ?? request.mediaURL) else { throw ParallelRangeDownloadError.invalidURL }
        }
        guard (200...299).contains(http.statusCode) else { throw ParallelRangeDownloadError.invalidResponse }
        try validateMediaResponse(http)
        let responseTotal = expectedBytes(from: http) ?? totalBytes
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var totalWritten = startingOffset
        for try await byte in bytes {
            if Task.isCancelled { throw CancellationError() }
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                totalWritten += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                await request.onProgress(DownloadProgress(bytesWritten: totalWritten, totalBytes: responseTotal))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            totalWritten += Int64(buffer.count)
        }
        try handle.close()
        guard totalWritten >= 1024 else { throw ParallelRangeDownloadError.responseTooSmall }
        let destination = request.destinationFilename
        try FileManager.default.moveItem(at: partialPath, to: destination)
        try? FileManager.default.removeItem(at: partialDirectory(for: request.jobID))
        return ParallelRangeResult(
            destination: destination,
            resumeState: DownloadResumeState(
                byteOffset: totalWritten,
                totalBytes: responseTotal,
                etag: etag ?? http.value(forHTTPHeaderField: "ETag"),
                lastModified: lastModified ?? http.value(forHTTPHeaderField: "Last-Modified"),
                startedAt: request.resumeState?.startedAt ?? .now,
                rangesCompleted: []
            )
        )
    }

    private static func makeRanges(totalBytes: Int64, startingOffset: Int64, chunkSize: Int64, maxStreams: Int) -> [ClosedRange<Int64>] {
        guard totalBytes > 0 else { return [] }
        guard maxStreams > 0 else { return [] }
        let ranges = max(1, maxStreams)
        let span = max(1, totalBytes - startingOffset)
        let stride = max(chunkSize, Int64((span + Int64(ranges) - 1) / Int64(ranges)))
        var output: [ClosedRange<Int64>] = []
        var cursor = startingOffset
        while cursor < totalBytes {
            let upper = min(totalBytes - 1, cursor + stride - 1)
            output.append(cursor...upper)
            cursor = upper + 1
        }
        return output
    }

    private static func formatRangeWindow(_ ranges: [ClosedRange<Int64>]) -> String {
        guard let first = ranges.first, let last = ranges.last else { return "0" }
        return "\(first.lowerBound)-\(last.upperBound)+"
    }

    private static func runRangeWorker(
        session: URLSession,
        request: ParallelRangeRequest,
        planned: ClosedRange<Int64>,
        totalBox: AtomicInt64,
        completedRangesBox: CompletedRangesBox,
        reporter: ProgressReporter,
        etag: String?,
        lastModified: String?,
        totalBytes: Int64?
    ) async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await runRangeWorkerOnce(
                    session: session,
                    request: request,
                    planned: planned,
                    totalBox: totalBox,
                    completedRangesBox: completedRangesBox,
                    reporter: reporter,
                    etag: etag,
                    lastModified: lastModified,
                    totalBytes: totalBytes
                )
                await request.onWorkerEvent("range [\(planned.lowerBound)–\(planned.upperBound)] done")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ParallelRangeDownloadError {
                if attempt >= 3 {
                    await request.onWorkerEvent("range [\(planned.lowerBound)–\(planned.upperBound)] failed: \(error.errorDescription ?? "unknown")")
                    throw error
                }
                let backoff = UInt64(50_000_000) * UInt64(attempt)
                try? await Task.sleep(nanoseconds: backoff)
            } catch {
                if attempt >= 3 {
                    await request.onWorkerEvent("range [\(planned.lowerBound)–\(planned.upperBound)] failed: \(error.localizedDescription)")
                    throw error
                }
                let backoff = UInt64(50_000_000) * UInt64(attempt)
                try? await Task.sleep(nanoseconds: backoff)
            }
        }
    }

    private static func runRangeWorkerOnce(
        session: URLSession,
        request: ParallelRangeRequest,
        planned: ClosedRange<Int64>,
        totalBox: AtomicInt64,
        completedRangesBox: CompletedRangesBox,
        reporter: ProgressReporter,
        etag: String?,
        lastModified: String?,
        totalBytes: Int64?
    ) async throws {
        var rangeRequest = URLRequest(url: request.mediaURL)
        rangeRequest.httpMethod = "GET"
        rangeRequest.timeoutInterval = 600
        applyHeaders(request.headers, to: &rangeRequest)
        rangeRequest.setValue("bytes=\(planned.lowerBound)-\(planned.upperBound)", forHTTPHeaderField: "Range")
        if let etag {
            rangeRequest.setValue("\"\(etag)\"", forHTTPHeaderField: "If-Range")
        } else if let lastModified {
            rangeRequest.setValue(lastModified, forHTTPHeaderField: "If-Range")
        }
        let (bytes, response) = try await session.bytes(for: rangeRequest)
        guard let http = response as? HTTPURLResponse else { throw ParallelRangeDownloadError.invalidResponse }
        if ProcessInfo.processInfo.environment["LUSTRE_TEST_SKIP_SAFETY"] != "1" {
            guard URLSafetyPolicy.isAllowed(http.url ?? request.mediaURL) else { throw ParallelRangeDownloadError.invalidURL }
        }
        if http.statusCode == 416 {
            throw ParallelRangeDownloadError.rangeRejected
        }
        if let totalBytes, planned.lowerBound >= totalBytes {
            return
        }
        guard (200...299).contains(http.statusCode) else { throw ParallelRangeDownloadError.invalidResponse }
        try validateMediaResponse(http)
        let partialPath = partialFile(for: request)
        if !FileManager.default.fileExists(atPath: partialPath.path) {
            if let totalBytes {
                try ensureFileSize(at: partialPath, totalBytes: totalBytes)
            } else {
                FileManager.default.createFile(atPath: partialPath.path, contents: nil)
            }
        }
        let handle = try FileHandle(forWritingTo: partialPath)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(planned.lowerBound))
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var cursor = planned.lowerBound
        for try await byte in bytes {
            if Task.isCancelled { throw CancellationError() }
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                cursor += Int64(buffer.count)
                totalBox.add(Int64(buffer.count))
                buffer.removeAll(keepingCapacity: true)
                await reporter.tick()
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            cursor += Int64(buffer.count)
            totalBox.add(Int64(buffer.count))
            buffer.removeAll(keepingCapacity: true)
        }
        try handle.close()
        completedRangesBox.append(planned)
        await reporter.tick()
    }

    private static func ensureFileSize(at url: URL, totalBytes: Int64?) throws {
        guard let totalBytes else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let current = (attrs?[.size] as? Int64) ?? 0
        if current >= totalBytes { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let gap = Int(totalBytes - current)
        if gap <= 0 { return }
        var written: Int = 0
        let chunkSize = 64 * 1024
        let zero = Data(count: chunkSize)
        while written < gap {
            let remaining = gap - written
            if remaining >= chunkSize {
                try handle.write(contentsOf: zero)
                written += chunkSize
            } else {
                try handle.write(contentsOf: Data(count: remaining))
                written += remaining
            }
        }
    }

    private static func finalizeNoOpDownload(request: ParallelRangeRequest, resumeState: DownloadResumeState?) async throws -> ParallelRangeResult {
        let partialPath = partialFile(for: request)
        try? FileManager.default.removeItem(at: partialPath)
        let destination = request.destinationFilename
        if !FileManager.default.fileExists(atPath: destination.path) {
            try Data().write(to: destination)
        }
        return ParallelRangeResult(destination: destination, resumeState: resumeState ?? DownloadResumeState())
    }

    private static func isResumeValid(state: DownloadResumeState, etag: String?, lastModified: String?, total: Int64?) -> Bool {
        guard state.isFresh() else { return false }
        if let etag, let stored = state.etag, etag != stored { return false }
        if let lastModified, let stored = state.lastModified, lastModified != stored { return false }
        if let total, let stored = state.totalBytes, total != stored { return false }
        return true
    }

    private static func applyHeaders(_ headers: [String: String], to request: inout URLRequest) {
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }
}

private extension CancellationError {
    static var destinationAlreadyComplete: CancellationError { CancellationError() }
}

private final class ProgressReporter: @unchecked Sendable {
    private let total: Int64?
    private let totalBox: AtomicInt64
    private let completedRangesBox: CompletedRangesBox
    private let plannedCount: Int
    private let onProgress: @Sendable (DownloadProgress) async -> Void
    private let onWorkerEvent: @Sendable (String) async -> Void
    private let lock = NSLock()
    private var lastEmitted: Int64 = 0

    init(request: ParallelRangeRequest, total: Int64?, totalBox: AtomicInt64, completedRangesBox: CompletedRangesBox, plannedCount: Int) {
        self.total = total
        self.totalBox = totalBox
        self.completedRangesBox = completedRangesBox
        self.plannedCount = plannedCount
        self.onProgress = request.onProgress
        self.onWorkerEvent = request.onWorkerEvent
    }

    func tick() async {
        let current = totalBox.value
        var shouldEmit = false
        lock.withLock {
            if current - lastEmitted >= 512 * 1024 {
                shouldEmit = true
                lastEmitted = current
            }
        }
        guard shouldEmit else { return }
        await onProgress(DownloadProgress(bytesWritten: current, totalBytes: total))
    }

    func finish() async {
        await onProgress(DownloadProgress(bytesWritten: totalBox.value, totalBytes: total))
        await onWorkerEvent("All \(plannedCount) range workers completed.")
    }
}

final class AtomicInt64: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int64
    init(value: Int64) { self.storage = value }
    var value: Int64 { lock.withLock { storage } }
    func add(_ delta: Int64) { lock.withLock { storage += delta } }
}

final class CompletedRangesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [ClosedRange<Int64>]
    init(initial: [ClosedRange<Int64>]) { self.ranges = initial }
    func append(_ range: ClosedRange<Int64>) {
        lock.withLock { ranges.append(range) }
    }
    func snapshot() -> [ClosedRange<Int64>] {
        lock.withLock { ranges }
    }
}

