import Foundation

public struct AgentConfiguration: Codable, Equatable, Sendable {
    public var downloadParallelRangeEnabled: Bool
    public var downloadMaxStreamsPerJob: Int
    public var downloadResumeTTLHours: Int
    public var downloadBenchEnabled: Bool

    public init(
        downloadParallelRangeEnabled: Bool = false,
        downloadMaxStreamsPerJob: Int = 8,
        downloadResumeTTLHours: Int = 72,
        downloadBenchEnabled: Bool = false
    ) {
        self.downloadParallelRangeEnabled = downloadParallelRangeEnabled
        self.downloadMaxStreamsPerJob = max(1, min(downloadMaxStreamsPerJob, 8))
        self.downloadResumeTTLHours = max(1, min(downloadResumeTTLHours, 24 * 30))
        self.downloadBenchEnabled = downloadBenchEnabled
    }

    public static let `default` = AgentConfiguration()

    public static let fileURL = AgentPaths.agentConfiguration

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try AgentPaths.prepare()
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL = AgentPaths.agentConfiguration) -> AgentConfiguration {
        guard let data = try? Data(contentsOf: url) else { return .default }
        return (try? JSONDecoder().decode(AgentConfiguration.self, from: data)) ?? .default
    }

    public func merged(with override: AgentConfiguration?) -> AgentConfiguration {
        guard let override else { return self }
        return AgentConfiguration(
            downloadParallelRangeEnabled: override.downloadParallelRangeEnabled,
            downloadMaxStreamsPerJob: override.downloadMaxStreamsPerJob,
            downloadResumeTTLHours: override.downloadResumeTTLHours,
            downloadBenchEnabled: override.downloadBenchEnabled
        )
    }
}
