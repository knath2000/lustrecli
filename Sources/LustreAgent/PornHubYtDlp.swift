import Foundation
import LustreCore

public enum PornHubURL {
    public static func viewKey(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.count == 1,
              items[0].name == "viewkey" else { return nil }
        return items[0].value.flatMap(PornHubFeedParser.safeViewKey)
    }

    public static func canonical(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "pornhub.com" || host == "www.pornhub.com",
              url.path == "/view_video.php",
              url.fragment == nil,
              let key = viewKey(url) else { return nil }
        return URL(string: "https://www.pornhub.com/view_video.php?viewkey=\(key)")
    }
}

public enum PornHubYtDlpError: Error, LocalizedError, Equatable {
    case executableUnavailable
    case invalidSource
    case invalidFormat
    case invalidMetadata
    case oversizedOutput
    case unsafeMetadata
    case noUsableFormats
    case sessionExpired
    case timedOut
    case cancelled
    case authenticationUnsupported
    case temporarilyUnavailable
    case processFailed
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .executableUnavailable: "yt-dlp is required at an approved system path."
        case .invalidSource: "PornHub downloads require a canonical public view_video.php URL."
        case .invalidFormat: "The saved yt-dlp format selector is invalid."
        case .invalidMetadata: "yt-dlp returned malformed metadata."
        case .oversizedOutput: "yt-dlp metadata exceeded the safe output limit."
        case .unsafeMetadata: "yt-dlp returned unsafe media metadata."
        case .noUsableFormats: "yt-dlp found no complete public audio-and-video formats."
        case .timedOut: "Public PornHub extraction timed out."
        case .cancelled: "Public PornHub extraction was cancelled."
        case .sessionExpired: "PornHub sign-in expired. Sign in again."
        case .authenticationUnsupported: "This PornHub item requires premium access, age verification, or another unavailable entitlement."
        case .temporarilyUnavailable: "PornHub is temporarily unavailable from this network or region."
        case .processFailed: "yt-dlp could not resolve this public PornHub item."
        case .invalidOutput: "yt-dlp did not produce exactly one valid media file."
        }
    }
}

public enum PornHubYtDlp {
    public static let maximumMetadataBytes = 8 * 1024 * 1024
    public static let allowedExecutables = [
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
        "/opt/local/bin/yt-dlp"
    ]

    public static func executableIsAllowed(_ url: URL) -> Bool {
        allowedExecutables.contains(url.standardizedFileURL.path)
    }

    public static func installedExecutable() -> URL? {
        allowedExecutables.lazy.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    public static func metadataArguments(source: URL, cookieFile: URL? = nil) throws -> [String] {
        guard PornHubURL.canonical(source) != nil else { throw PornHubYtDlpError.invalidSource }
        return try genericMetadataArguments(source: source, cookieFile: cookieFile)
    }

    static func genericMetadataArguments(source: URL, cookieFile: URL? = nil) throws -> [String] {
        guard safePublicSource(source) else { throw PornHubYtDlpError.invalidSource }
        var arguments = ["--no-playlist", "--dump-single-json", "--no-download", "--no-warnings", "--socket-timeout", "20"]
        if let cookieFile { arguments.append(contentsOf: ["--cookies", cookieFile.path]) }
        arguments.append(source.absoluteString)
        return arguments
    }

    public static func materializationArguments(source: URL, formatSelector: String, directory: URL, cookieFile: URL? = nil) throws -> [String] {
        guard PornHubURL.canonical(source) != nil else { throw PornHubYtDlpError.invalidSource }
        return try genericMaterializationArguments(source: source, formatSelector: formatSelector, directory: directory, cookieFile: cookieFile, outputPrefix: "lustre-pornhub")
    }

    static func genericMaterializationArguments(source: URL, formatSelector: String, directory: URL, cookieFile: URL? = nil, outputPrefix: String = "lustre-video") throws -> [String] {
        guard safePublicSource(source) else { throw PornHubYtDlpError.invalidSource }
        guard safeFormatSelector(formatSelector) else { throw PornHubYtDlpError.invalidFormat }
        var arguments = [
            "--no-playlist", "--no-warnings", "--restrict-filenames",
            "--format", formatSelector, "--merge-output-format", "mp4",
            "--output", directory.appendingPathComponent("\(outputPrefix).%(ext)s").path,
            "--newline", "--progress",
            "--progress-template", "download:LUSTRE_PROGRESS:v1\t%(progress.status)s\t%(progress.downloaded_bytes|NA)s\t%(progress.total_bytes|NA)s\t%(progress.total_bytes_estimate|NA)s\t%(progress.speed|NA)s\t%(progress.eta|NA)s\t%(progress.fragment_index|NA)s\t%(progress.fragment_count|NA)s\tmedia"
        ]
        if let cookieFile { arguments.append(contentsOf: ["--cookies", cookieFile.path]) }
        arguments.append(source.absoluteString)
        return arguments
    }

    public static func resolve(source: URL, cookies: [PornHubCookieRecord] = []) async throws -> ProviderResolution {
        guard let executable = installedExecutable() else { throw PornHubYtDlpError.executableUnavailable }
        let cookieFile = try cookies.isEmpty ? nil : PornHubCookieFile.create(in: privateCookieDirectory(), cookies: cookies)
        defer { if let cookieFile { try? PornHubCookieFile.remove(cookieFile) } }
        let result = try await run(executable: executable, arguments: metadataArguments(source: source, cookieFile: cookieFile), timeout: 60, stdoutCap: maximumMetadataBytes, stderrCap: 128 * 1024)
        guard result.status == 0 else { throw classifiedFailure(result.stderr) }
        return try parseMetadata(result.stdout, source: source)
    }

    public static func materialize(source: URL, title: String?, formatSelector: String, directory: URL, cookies: [PornHubCookieRecord] = [], onProgress: @escaping @Sendable (DownloadProgress) async -> Void = { _ in }) async throws -> URL {
        guard let executable = installedExecutable() else { throw PornHubYtDlpError.executableUnavailable }
        return try await materialize(executable: executable, source: source, title: title, formatSelector: formatSelector, directory: directory, cookies: cookies, onProgress: onProgress, allowUnapprovedExecutable: false)
    }

    static func materializeForTesting(executable: URL, source: URL, title: String? = nil, formatSelector: String, directory: URL, cookies: [PornHubCookieRecord] = [], timeout: TimeInterval = 7_200, onProgress: @escaping @Sendable (DownloadProgress) async -> Void = { _ in }) async throws -> URL {
        try await materialize(executable: executable, source: source, title: title, formatSelector: formatSelector, directory: directory, cookies: cookies, timeout: timeout, onProgress: onProgress, allowUnapprovedExecutable: true)
    }

    private static func materialize(executable: URL, source: URL, title: String?, formatSelector: String, directory: URL, cookies: [PornHubCookieRecord], timeout: TimeInterval = 7_200, onProgress: @escaping @Sendable (DownloadProgress) async -> Void, allowUnapprovedExecutable: Bool) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let working = directory.appendingPathComponent(".lustre-pornhub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: working.path)
        defer { try? FileManager.default.removeItem(at: working) }
        let cookieFile = try cookies.isEmpty ? nil : PornHubCookieFile.create(in: working, cookies: cookies)
        defer { if let cookieFile { try? PornHubCookieFile.remove(cookieFile) } }
        await onProgress(DownloadProgress(bytesWritten: 0, phase: .materializing))
        let result = try await run(
            executable: executable,
            arguments: materializationArguments(source: source, formatSelector: formatSelector, directory: working, cookieFile: cookieFile),
            timeout: timeout,
            stdoutCap: 256 * 1024,
            stderrCap: 512 * 1024,
            onProgress: { sample in await onProgress(sample.progress) },
            allowUnapprovedExecutable: allowUnapprovedExecutable
        )
        guard result.status == 0 else { throw classifiedFailure(result.stderr) }
        let outputs = try FileManager.default.contentsOfDirectory(
            at: working,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter {
            let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 0) >= 1_024
        }
        guard outputs.count == 1 else { throw PornHubYtDlpError.invalidOutput }
        let destination = FilenamePolicy.uniquePornHubURL(directory: directory, title: title, source: source, fileExtension: outputs[0].pathExtension)
        try FileManager.default.moveItem(at: outputs[0], to: destination)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        await onProgress(DownloadProgress(bytesWritten: size ?? 0, totalBytes: size, phase: .postProcessing))
        return destination
    }

    public static func parseMetadata(_ data: Data, source: URL) throws -> ProviderResolution {
        guard data.count <= maximumMetadataBytes else { throw PornHubYtDlpError.oversizedOutput }
        guard PornHubURL.canonical(source) != nil else { throw PornHubYtDlpError.invalidMetadata }
        return try parseMetadata(data, source: source, provider: .pornHub, method: "Agent yt-dlp public metadata", trace: [
            "Resolved anonymous public PornHub metadata with agent-owned yt-dlp.",
            "Signed media URLs were not persisted or exposed."
        ])
    }

    static func parseGenericMetadata(_ data: Data, source: URL) throws -> ProviderResolution {
        guard data.count <= maximumMetadataBytes else { throw PornHubYtDlpError.oversizedOutput }
        guard safePublicSource(source) else { throw PornHubYtDlpError.invalidMetadata }
        return try parseMetadata(data, source: source, provider: .ytDlp, method: "Agent generic yt-dlp metadata", trace: [
            "Resolved public source metadata with the agent-owned generic yt-dlp fallback.",
            "Signed media URLs were not persisted or exposed."
        ])
    }

    private static func parseMetadata(_ data: Data, source: URL, provider: ProviderKind, method: String, trace: [String]) throws -> ProviderResolution {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formats = root["formats"] as? [[String: Any]] else { throw PornHubYtDlpError.invalidMetadata }
        let rootHeaders = try sanitizedHeaders(root["http_headers"])
        var seenSelectors = Set<String>()
        var seenQualities = Set<String>()
        var qualities: [(height: Int, quality: ResolvedQuality)] = []
        let audioFormatID = formats
            .filter { !hasVideo($0) && hasAudio($0) }
            .sorted { number($0["abr"]) > number($1["abr"]) }
            .compactMap { $0["format_id"] as? String }
            .first(where: safeFormatSelector)
        for format in formats {
            guard let id = format["format_id"] as? String, safeFormatSelector(id),
                  let rawURL = format["url"] as? String, let mediaURL = URL(string: rawURL),
                  mediaURL.scheme?.lowercased() == "https", URLSafetyPolicy.isAllowed(mediaURL),
                  hasVideo(format) else { continue }
            let selector: String
            if isCombinedFormat(format, mediaURL: mediaURL) {
                selector = id
            } else if let audioFormatID {
                selector = "\(id)+\(audioFormatID)"
            } else {
                continue
            }
            guard safeFormatSelector(selector), seenSelectors.insert(selector).inserted else { continue }
            let height = number(format["height"])
            let ext = ((format["ext"] as? String) ?? mediaURL.pathExtension).lowercased()
            let qualityKey = "\(height):\(ext)"
            guard seenQualities.insert(qualityKey).inserted else { continue }
            var headers = rootHeaders
            for (key, value) in try sanitizedHeaders(format["http_headers"]) { headers[key] = value }
            qualities.append((
                height,
                ResolvedQuality(
                    label: height > 0 ? "\(height)p \(ext.isEmpty ? "Video" : ext.uppercased())" : (ext.isEmpty ? "Video" : ext.uppercased()),
                    url: source,
                    headers: headers,
                    resolutionMethod: method,
                    mediaKind: .ytDlp,
                    formatSelector: selector
                )
            ))
        }
        qualities.sort {
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.quality.label < $1.quality.label
        }
        guard !qualities.isEmpty else { throw PornHubYtDlpError.noUsableFormats }
        let thumbnail = (root["thumbnail"] as? String).flatMap(URL.init(string:)).flatMap {
            $0.scheme?.lowercased() == "https" && URLSafetyPolicy.isAllowed($0) ? $0 : nil
        }
        return ProviderResolution(
            sourcePageURL: source,
            provider: provider,
            title: (root["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            thumbnailURL: thumbnail,
            qualities: qualities.map(\.quality),
            trace: trace
        )
    }

    static func safeFormatSelector(_ value: String) -> Bool {
        guard (1...128).contains(value.count),
              let regex = try? NSRegularExpression(pattern: #"^[A-Za-z0-9._-]+(?:\+[A-Za-z0-9._-]+)?$"#) else { return false }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func hasVideo(_ format: [String: Any]) -> Bool {
        if let codec = (format["vcodec"] as? String)?.lowercased() { return codec != "none" }
        return number(format["height"]) > 0
    }

    private static func hasAudio(_ format: [String: Any]) -> Bool {
        ((format["acodec"] as? String)?.lowercased()).map { $0 != "none" } ?? false
    }

    private static func isCombinedFormat(_ format: [String: Any], mediaURL: URL) -> Bool {
        if hasAudio(format) { return true }
        // PornHub's direct progressive MP4 entries currently omit both codec
        // fields even though each file contains audio and video. An explicit
        // `acodec: none` still means video-only and must never be treated as complete.
        guard format["vcodec"] == nil, format["acodec"] == nil else { return false }
        let protocolName = (format["protocol"] as? String)?.lowercased()
        let ext = ((format["ext"] as? String) ?? mediaURL.pathExtension).lowercased()
        return protocolName == "https" && ["mp4", "webm", "mov"].contains(ext)
    }

    private static func number(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    private static func sanitizedHeaders(_ raw: Any?) throws -> [String: String] {
        guard let raw else { return [:] }
        guard let values = raw as? [String: Any] else { throw PornHubYtDlpError.unsafeMetadata }
        var result: [String: String] = [:]
        let namePattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9-]{1,64}$"#)
        for (key, value) in values {
            guard let value = value as? String, value.count <= 4_096,
                  namePattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil,
                  !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else {
                throw PornHubYtDlpError.unsafeMetadata
            }
            result[key] = value
        }
        return result
    }

    static func safePublicSource(_ source: URL) -> Bool {
        source.scheme?.lowercased() == "https"
            && source.host != nil
            && source.user == nil
            && source.password == nil
            && URLSafetyPolicy.isAllowed(source)
    }

    public static func classifiedFailure(_ data: Data) -> PornHubYtDlpError {
        let message = String(decoding: data, as: UTF8.self).lowercased()
        if ["login required", "log in", "sign in", "session expired", "invalid session", "authentication required", "cookies are no longer valid"].contains(where: message.contains) {
            return .sessionExpired
        }
        if ["premium", "age verification", "members only"].contains(where: message.contains) {
            return .authenticationUnsupported
        }
        if ["geo", "region", "temporarily unavailable", "blocked"].contains(where: message.contains) {
            return .temporarilyUnavailable
        }
        return .processFailed
    }

    private static func privateCookieDirectory() -> URL {
        AgentPaths.applicationSupport.appendingPathComponent("pornhub-cookies", isDirectory: true)
    }

    struct ProcessResult: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    static func run(executable: URL, arguments: [String], timeout: TimeInterval, stdoutCap: Int, stderrCap: Int, onProgress: @escaping @Sendable (YtDlpProgressSample) async -> Void = { _ in }, allowUnapprovedExecutable: Bool = false) async throws -> ProcessResult {
        guard allowUnapprovedExecutable || executableIsAllowed(executable) else { throw PornHubYtDlpError.executableUnavailable }
        do {
            let result = try await StreamingProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout, stdoutCap: stdoutCap, stderrCap: stderrCap, onProgress: onProgress)
            return ProcessResult(status: result.status, stdout: result.stdout, stderr: result.stderrDiagnostics)
        } catch let error as StreamingProcessRunnerError {
            switch error {
            case .timedOut: throw PornHubYtDlpError.timedOut
            case .cancelled: throw PornHubYtDlpError.cancelled
            case .processFailed, .streamFailed: throw PornHubYtDlpError.processFailed
            }
        } catch {
            throw PornHubYtDlpError.processFailed
        }
    }
}
