import Foundation

public enum PornHubAuthState: String, Codable, Equatable, Sendable { case signedOut, signingIn, signedIn, expired }

public struct PornHubAuthStatus: Codable, Equatable, Sendable {
    public let state: PornHubAuthState
    public let lastValidatedAt: Date?
    public let message: String?
    public init(state: PornHubAuthState, lastValidatedAt: Date? = nil, message: String? = nil) {
        self.state = state; self.lastValidatedAt = lastValidatedAt; self.message = message
    }
}

public enum JobStatus: String, Codable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled
    case verificationRequired
}

public enum JobAction: String, Codable, Sendable {
    case pause
    case resume
    case cancel
    case retry
    case forceStart
}

public struct JobLogEntry: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable {
        case info
        case error
    }

    public let timestamp: Date
    public let level: Level
    public let message: String

    public init(timestamp: Date = .now, level: Level, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

public enum ProviderKind: String, Codable, Sendable {
    case direct
    case allPornStream
    case hqPorner = "hqporner"
    case doodStream
    case myDaddy
    case mixDrop
    case streamTape
    case luluStream
    case vidara
    case pornHub = "pornhub"
}

public enum ProviderAttemptOutcome: String, Codable, Sendable {
    case resolved
    case failed
    case verificationRequired
    case timedOut
}

public struct ProviderAttempt: Codable, Equatable, Sendable {
    public let providerName: String
    public let sourceURL: URL?
    public let outcome: ProviderAttemptOutcome
    public let resolutionMethod: String?
    public let reason: String?
    public let diagnostics: [String]?

    public init(
        providerName: String,
        sourceURL: URL?,
        outcome: ProviderAttemptOutcome,
        resolutionMethod: String? = nil,
        reason: String? = nil,
        diagnostics: [String]? = nil
    ) {
        self.providerName = providerName
        self.sourceURL = sourceURL
        self.outcome = outcome
        self.resolutionMethod = resolutionMethod
        self.reason = reason
        self.diagnostics = diagnostics
    }
}

public enum MediaKind: String, Codable, Sendable {
    case direct
    case hls
    case ytDlp = "yt-dlp"
}

public struct ResolvedQuality: Codable, Equatable, Sendable {
    public let label: String
    public let url: URL
    public let headers: [String: String]
    public let resolutionMethod: String
    public let mediaKind: MediaKind
    public let formatSelector: String?

    public init(label: String, url: URL, headers: [String: String] = [:], resolutionMethod: String, mediaKind: MediaKind = .direct, formatSelector: String? = nil) {
        self.label = label
        self.url = url
        self.headers = headers
        self.resolutionMethod = resolutionMethod
        self.mediaKind = mediaKind
        self.formatSelector = formatSelector
    }

    private enum CodingKeys: String, CodingKey {
        case label, url, headers, resolutionMethod, mediaKind, formatSelector
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        url = try container.decode(URL.self, forKey: .url)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        resolutionMethod = try container.decode(String.self, forKey: .resolutionMethod)
        mediaKind = try container.decodeIfPresent(MediaKind.self, forKey: .mediaKind) ?? .direct
        formatSelector = try container.decodeIfPresent(String.self, forKey: .formatSelector)
    }
}

public struct ProviderResolution: Codable, Equatable, Sendable {
    public let sourcePageURL: URL
    public let provider: ProviderKind
    public let title: String?
    public let thumbnailURL: URL?
    public let qualities: [ResolvedQuality]
    public let trace: [String]

    public init(
        sourcePageURL: URL,
        provider: ProviderKind,
        title: String? = nil,
        thumbnailURL: URL? = nil,
        qualities: [ResolvedQuality],
        trace: [String]
    ) {
        self.sourcePageURL = sourcePageURL
        self.provider = provider
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.qualities = qualities
        self.trace = trace
    }
}

public enum TransferPhase: String, Codable, Equatable, Sendable { case resolving, downloading, materializing, postProcessing, uploading, verifying }

public struct DownloadProgress: Equatable, Sendable {
    public let bytesWritten: Int64
    public let totalBytes: Int64?
    public let phase: TransferPhase?
    public let totalIsEstimated: Bool
    public let bytesPerSecond: Double?
    public let etaSeconds: Int?

    public init(bytesWritten: Int64, totalBytes: Int64? = nil, phase: TransferPhase? = nil, totalIsEstimated: Bool = false, bytesPerSecond: Double? = nil, etaSeconds: Int? = nil) {
        self.bytesWritten = max(0, bytesWritten)
        self.totalBytes = totalBytes.map { max(0, $0) }
        self.phase = phase
        self.totalIsEstimated = totalIsEstimated
        self.bytesPerSecond = bytesPerSecond.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.etaSeconds = etaSeconds.flatMap { (0...7_200).contains($0) ? $0 : nil }
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(bytesWritten) / Double(totalBytes), 0), 1)
    }
}

public struct DownloadJob: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sourcePageURL: URL
    public var preferredQualityLabel: String?
    public var destination: String
    public var status: JobStatus
    public var message: String
    public var progress: Double?
    public var downloadedBytes: Int64?
    public var totalBytes: Int64?
    public var transferPhase: TransferPhase?
    public var phaseProgress: Double?
    public var phaseBytes: Int64?
    public var phaseTotalBytes: Int64?
    public var phaseTotalIsEstimated: Bool?
    public var phaseBytesPerSecond: Double?
    public var phaseETASeconds: Int?
    public var attempts: Int
    public var logs: [JobLogEntry]?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sourcePageURL: URL,
        preferredQualityLabel: String? = nil,
        destination: String = "local",
        status: JobStatus = .queued,
        message: String = "Waiting for the resolver worker.",
        progress: Double? = nil,
        downloadedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        transferPhase: TransferPhase? = nil,
        phaseProgress: Double? = nil,
        phaseBytes: Int64? = nil,
        phaseTotalBytes: Int64? = nil,
        phaseTotalIsEstimated: Bool? = nil,
        phaseBytesPerSecond: Double? = nil,
        phaseETASeconds: Int? = nil,
        attempts: Int = 0,
        logs: [JobLogEntry]? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.sourcePageURL = sourcePageURL
        self.preferredQualityLabel = preferredQualityLabel
        self.destination = destination
        self.status = status
        self.message = message
        self.progress = progress
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.transferPhase = transferPhase
        self.phaseProgress = phaseProgress
        self.phaseBytes = phaseBytes
        self.phaseTotalBytes = phaseTotalBytes
        self.phaseTotalIsEstimated = phaseTotalIsEstimated
        self.phaseBytesPerSecond = phaseBytesPerSecond
        self.phaseETASeconds = phaseETASeconds
        self.attempts = attempts
        self.logs = logs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ExtractionResult: Codable, Equatable, Sendable {
    public let sourcePageURL: URL
    public let isDirectMedia: Bool
    public let resolutionState: String
    public let trace: [String]
    public let resolution: ProviderResolution?
    public let providerAttempts: [ProviderAttempt]

    public init(
        sourcePageURL: URL,
        isDirectMedia: Bool,
        resolutionState: String,
        trace: [String],
        resolution: ProviderResolution? = nil,
        providerAttempts: [ProviderAttempt] = []
    ) {
        self.sourcePageURL = sourcePageURL
        self.isDirectMedia = isDirectMedia
        self.resolutionState = resolutionState
        self.trace = trace
        self.resolution = resolution
        self.providerAttempts = providerAttempts
    }
}

public struct CreateJobRequest: Codable, Sendable {
    public let id: UUID?
    public let sourcePageURL: URL
    public let preferredQualityLabel: String?
    public let destination: String?

    public init(id: UUID? = nil, sourcePageURL: URL, preferredQualityLabel: String? = nil, destination: String? = nil) {
        self.id = id
        self.sourcePageURL = sourcePageURL
        self.preferredQualityLabel = preferredQualityLabel
        self.destination = destination
    }
}
