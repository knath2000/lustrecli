import Foundation
import LustreCore

public struct ProviderCDNObservation: Codable, Equatable, Sendable {
    public let provider: ProviderKind
    public let host: String
    public let firstSeenAt: Date
    public var lastSeenAt: Date
    public var discoveryCount: Int
    public var successfulProbeCount: Int
    public var failedProbeCount: Int

    public init(
        provider: ProviderKind,
        host: String,
        firstSeenAt: Date,
        lastSeenAt: Date,
        discoveryCount: Int,
        successfulProbeCount: Int,
        failedProbeCount: Int
    ) {
        self.provider = provider
        self.host = host
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.discoveryCount = discoveryCount
        self.successfulProbeCount = successfulProbeCount
        self.failedProbeCount = failedProbeCount
    }
}

public actor ProviderCDNRegistry {
    private let fileURL: URL
    private let maximumEntries: Int
    private let now: @Sendable () -> Date
    private var observations: [ProviderCDNObservation]

    public init(
        fileURL: URL = AgentPaths.applicationSupport.appending(path: "provider-cdn-observations.json"),
        maximumEntries: Int = 256,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fileURL = fileURL
        self.maximumEntries = max(1, maximumEntries)
        self.now = now
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ProviderCDNObservation].self, from: data) {
            observations = Array(decoded.prefix(max(1, maximumEntries)))
        } else {
            observations = []
        }
    }

    public func observe(url: URL, provider: ProviderKind, probeSucceeded: Bool?) {
        guard URLSafetyPolicy.isAllowed(url),
              let rawHost = url.host?.lowercased(),
              (1...253).contains(rawHost.count),
              rawHost.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") })
        else { return }

        let timestamp = now()
        if let index = observations.firstIndex(where: { $0.provider == provider && $0.host == rawHost }) {
            observations[index].lastSeenAt = timestamp
            observations[index].discoveryCount += 1
            if probeSucceeded == true { observations[index].successfulProbeCount += 1 }
            if probeSucceeded == false { observations[index].failedProbeCount += 1 }
        } else {
            observations.append(ProviderCDNObservation(
                provider: provider,
                host: rawHost,
                firstSeenAt: timestamp,
                lastSeenAt: timestamp,
                discoveryCount: 1,
                successfulProbeCount: probeSucceeded == true ? 1 : 0,
                failedProbeCount: probeSucceeded == false ? 1 : 0
            ))
        }
        observations.sort {
            if $0.lastSeenAt != $1.lastSeenAt { return $0.lastSeenAt > $1.lastSeenAt }
            if $0.provider.rawValue != $1.provider.rawValue { return $0.provider.rawValue < $1.provider.rawValue }
            return $0.host < $1.host
        }
        observations = Array(observations.prefix(maximumEntries))
        persist()
    }

    public func all() -> [ProviderCDNObservation] {
        observations
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(observations) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
