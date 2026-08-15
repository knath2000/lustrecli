import Foundation
import LustreCore

public enum GenericYtDlpError: Error, LocalizedError, Equatable {
    case executableUnavailable
    case invalidSource
    case invalidFormat
    case invalidMetadata
    case oversizedOutput
    case unsafeMetadata
    case noUsableFormats
    case timedOut
    case cancelled
    case processFailed
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .executableUnavailable: "yt-dlp is required at an approved system path."
        case .invalidSource: "Generic yt-dlp requires a public HTTPS source URL."
        case .invalidFormat: "The saved yt-dlp format selector is invalid."
        case .invalidMetadata: "yt-dlp returned malformed metadata."
        case .oversizedOutput: "yt-dlp metadata exceeded the safe output limit."
        case .unsafeMetadata: "yt-dlp returned unsafe media metadata."
        case .noUsableFormats: "yt-dlp found no complete audio-and-video formats."
        case .timedOut: "Generic yt-dlp extraction timed out."
        case .cancelled: "Generic yt-dlp extraction was cancelled."
        case .processFailed: "yt-dlp could not resolve this public source."
        case .invalidOutput: "yt-dlp did not produce exactly one valid media file."
        }
    }
}

public enum GenericYtDlp {
    public static func resolve(source: URL) async throws -> ProviderResolution {
        do {
            guard let executable = PornHubYtDlp.installedExecutable() else { throw PornHubYtDlpError.executableUnavailable }
            let result = try await PornHubYtDlp.run(
                executable: executable,
                arguments: try PornHubYtDlp.genericMetadataArguments(source: source),
                timeout: 60,
                stdoutCap: PornHubYtDlp.maximumMetadataBytes,
                stderrCap: 128 * 1024
            )
            guard result.status == 0 else { throw PornHubYtDlp.classifiedFailure(result.stderr) }
            return try PornHubYtDlp.parseGenericMetadata(result.stdout, source: source)
        } catch {
            throw mapped(error)
        }
    }

    public static func materialize(
        source: URL,
        title: String?,
        formatSelector: String,
        directory: URL,
        onProgress: @escaping @Sendable (DownloadProgress) async -> Void = { _ in }
    ) async throws -> URL {
        do {
            guard let executable = PornHubYtDlp.installedExecutable() else { throw PornHubYtDlpError.executableUnavailable }
            return try await materialize(
                executable: executable,
                source: source,
                title: title,
                formatSelector: formatSelector,
                directory: directory,
                onProgress: onProgress,
                allowUnapprovedExecutable: false
            )
        } catch {
            throw mapped(error)
        }
    }

    static func resolveForTesting(executable: URL, source: URL) async throws -> ProviderResolution {
        let result = try await PornHubYtDlp.run(
            executable: executable,
            arguments: try PornHubYtDlp.genericMetadataArguments(source: source),
            timeout: 10,
            stdoutCap: PornHubYtDlp.maximumMetadataBytes,
            stderrCap: 128 * 1024,
            allowUnapprovedExecutable: true
        )
        guard result.status == 0 else { throw PornHubYtDlp.classifiedFailure(result.stderr) }
        return try PornHubYtDlp.parseGenericMetadata(result.stdout, source: source)
    }

    static func materializeForTesting(
        executable: URL,
        source: URL,
        title: String? = nil,
        formatSelector: String,
        directory: URL,
        timeout: TimeInterval = 10,
        onProgress: @escaping @Sendable (DownloadProgress) async -> Void = { _ in }
    ) async throws -> URL {
        try await materialize(
            executable: executable,
            source: source,
            title: title,
            formatSelector: formatSelector,
            directory: directory,
            timeout: timeout,
            onProgress: onProgress,
            allowUnapprovedExecutable: true
        )
    }

    private static func materialize(
        executable: URL,
        source: URL,
        title: String?,
        formatSelector: String,
        directory: URL,
        timeout: TimeInterval = 7_200,
        onProgress: @escaping @Sendable (DownloadProgress) async -> Void,
        allowUnapprovedExecutable: Bool
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let working = directory.appendingPathComponent(".lustre-ytdlp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: working.path)
        defer { try? FileManager.default.removeItem(at: working) }
        await onProgress(DownloadProgress(bytesWritten: 0, phase: .materializing))
        let result = try await PornHubYtDlp.run(
            executable: executable,
            arguments: try PornHubYtDlp.genericMaterializationArguments(source: source, formatSelector: formatSelector, directory: working),
            timeout: timeout,
            stdoutCap: 256 * 1024,
            stderrCap: 512 * 1024,
            onProgress: { sample in await onProgress(sample.progress) },
            allowUnapprovedExecutable: allowUnapprovedExecutable
        )
        guard result.status == 0 else { throw PornHubYtDlp.classifiedFailure(result.stderr) }
        let outputs = try FileManager.default.contentsOfDirectory(
            at: working,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter {
            let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 0) >= 1_024
        }
        guard outputs.count == 1 else { throw PornHubYtDlpError.invalidOutput }
        let destination = FilenamePolicy.uniqueYtDlpURL(directory: directory, title: title, fileExtension: outputs[0].pathExtension)
        try FileManager.default.moveItem(at: outputs[0], to: destination)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        await onProgress(DownloadProgress(bytesWritten: size ?? 0, totalBytes: size, phase: .postProcessing))
        return destination
    }

    private static func mapped(_ error: Error) -> GenericYtDlpError {
        guard let error = error as? PornHubYtDlpError else { return .processFailed }
        return switch error {
        case .executableUnavailable: .executableUnavailable
        case .invalidSource: .invalidSource
        case .invalidFormat: .invalidFormat
        case .invalidMetadata: .invalidMetadata
        case .oversizedOutput: .oversizedOutput
        case .unsafeMetadata: .unsafeMetadata
        case .noUsableFormats: .noUsableFormats
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .invalidOutput: .invalidOutput
        case .sessionExpired, .authenticationUnsupported, .temporarilyUnavailable, .processFailed: .processFailed
        }
    }
}
