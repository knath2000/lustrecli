import Foundation

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
}

public enum ProviderKind: String, Codable, Sendable {
    case direct
    case doodStream
    case mixDrop
    case streamTape
}

public struct ResolvedQuality: Codable, Equatable, Sendable {
    public let label: String
    public let url: URL
    public let headers: [String: String]
    public let resolutionMethod: String

    public init(label: String, url: URL, headers: [String: String] = [:], resolutionMethod: String) {
        self.label = label
        self.url = url
        self.headers = headers
        self.resolutionMethod = resolutionMethod
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

public struct DownloadJob: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sourcePageURL: URL
    public var preferredQualityLabel: String?
    public var destination: String
    public var status: JobStatus
    public var message: String
    public var attempts: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sourcePageURL: URL,
        preferredQualityLabel: String? = nil,
        destination: String = "local",
        status: JobStatus = .queued,
        message: String = "Waiting for the resolver worker.",
        attempts: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.sourcePageURL = sourcePageURL
        self.preferredQualityLabel = preferredQualityLabel
        self.destination = destination
        self.status = status
        self.message = message
        self.attempts = attempts
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

    public init(
        sourcePageURL: URL,
        isDirectMedia: Bool,
        resolutionState: String,
        trace: [String],
        resolution: ProviderResolution? = nil
    ) {
        self.sourcePageURL = sourcePageURL
        self.isDirectMedia = isDirectMedia
        self.resolutionState = resolutionState
        self.trace = trace
        self.resolution = resolution
    }
}

public struct CreateJobRequest: Codable, Sendable {
    public let sourcePageURL: URL
    public let preferredQualityLabel: String?
    public let destination: String?

    public init(sourcePageURL: URL, preferredQualityLabel: String? = nil, destination: String? = nil) {
        self.sourcePageURL = sourcePageURL
        self.preferredQualityLabel = preferredQualityLabel
        self.destination = destination
    }
}
