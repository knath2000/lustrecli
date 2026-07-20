import Foundation
import LustreCore

public actor AgentService {
    private let jobs: JobStore
    private let resolver: StaticProviderResolver

    public init(databaseURL: URL = AgentPaths.database, resolver: StaticProviderResolver = StaticProviderResolver()) throws {
        self.jobs = try JobStore(databaseURL: databaseURL)
        self.resolver = resolver
    }

    public func health() -> [String: String] {
        ["status": "ok"]
    }

    public func allJobs() async throws -> [DownloadJob] {
        try await jobs.allJobs()
    }

    public func extract(url: URL) async throws -> ExtractionResult {
        guard URLSafetyPolicy.isAllowed(url) else {
            throw AgentServiceError.invalidURL
        }
        do {
            let resolution = try await resolver.resolve(url: url)
            return ExtractionResult(
                sourcePageURL: url,
                isDirectMedia: resolution.provider == .direct,
                resolutionState: "resolved",
                trace: resolution.trace,
                resolution: resolution
            )
        } catch ProviderResolverError.cloudflareChallenge {
            return ExtractionResult(
                sourcePageURL: url,
                isDirectMedia: false,
                resolutionState: "verificationRequired",
                trace: ["Provider requires interactive browser verification; no WebKit fallback is installed in the agent."]
            )
        } catch ProviderResolverError.unsupportedProvider {
            return ExtractionResult(
                sourcePageURL: url,
                isDirectMedia: false,
                resolutionState: "pendingProviderResolver",
                trace: ["Stored original source page URL.", "No static resolver is installed for this provider."]
            )
        }
    }

    public func createJob(_ request: CreateJobRequest) async throws -> DownloadJob {
        _ = try await extract(url: request.sourcePageURL)
        let job = DownloadJob(
            sourcePageURL: request.sourcePageURL,
            preferredQualityLabel: request.preferredQualityLabel,
            destination: request.destination ?? "local"
        )
        try await jobs.create(job)
        return job
    }

    public func apply(_ action: JobAction, to id: UUID) async throws -> DownloadJob {
        try await jobs.apply(action, to: id)
    }
}

enum AgentServiceError: Error, LocalizedError {
    case invalidURL
    var errorDescription: String? { "Only absolute HTTP(S) URLs can be processed." }
}
