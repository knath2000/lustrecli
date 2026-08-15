import Foundation
import LustreCore

public struct DirectExtractor: Sendable {
    public typealias PornHubResolver = @Sendable (URL) async throws -> ProviderResolution
    public typealias GenericResolver = @Sendable (URL) async throws -> ProviderResolution
    public typealias AllPornStreamHTML = @Sendable (URL) async throws -> String

    private let resolver: StaticProviderResolver
    private let pornHubResolver: PornHubResolver
    private let genericResolver: GenericResolver
    private let allPornStreamHTML: AllPornStreamHTML?

    public init(
        resolver: StaticProviderResolver = StaticProviderResolver(),
        pornHubResolver: @escaping PornHubResolver = { try await PornHubYtDlp.resolve(source: $0, cookies: []) },
        genericResolver: @escaping GenericResolver = GenericYtDlp.resolve,
        allPornStreamHTML: AllPornStreamHTML? = nil
    ) {
        self.resolver = resolver
        self.pornHubResolver = pornHubResolver
        self.genericResolver = genericResolver
        self.allPornStreamHTML = allPornStreamHTML
    }

    public func extract(url: URL) async throws -> ExtractionResult {
        guard URLSafetyPolicy.isAllowed(url) else { throw AgentServiceError.invalidURL }
        if AllPornStreamResolver.isAllPornStreamPostURL(url) {
            return await extractAllPornStream(url: url)
        }
        if let canonical = PornHubURL.canonical(url) {
            return result(url: canonical, resolution: try await pornHubResolver(canonical))
        }
        do {
            return result(url: url, resolution: try await resolver.resolve(url: url))
        } catch ProviderResolverError.cloudflareChallenge {
            return ExtractionResult(
                sourcePageURL: url,
                isDirectMedia: false,
                resolutionState: "verificationRequired",
                trace: ["Provider requires interactive browser verification."]
            )
        } catch ProviderResolverError.unsupportedProvider {
            return result(url: url, resolution: try await genericResolver(url))
        }
    }

    private func result(url: URL, resolution: ProviderResolution) -> ExtractionResult {
        ExtractionResult(
            sourcePageURL: url,
            isDirectMedia: resolution.provider == .direct,
            resolutionState: "resolved",
            trace: resolution.trace,
            resolution: resolution
        )
    }

    private func extractAllPornStream(url: URL) async -> ExtractionResult {
        do {
            let aggregate: AllPornStreamResolution
            do {
                aggregate = try await AllPornStreamResolver(
                    fetch: resolver.pageFetch,
                    providerResolver: resolver
                ).resolve(postURL: url)
            } catch ProviderResolverError.cloudflareChallenge {
                guard let allPornStreamHTML else {
                    return verificationRequired(url: url)
                }
                let html = try await allPornStreamHTML(url)
                aggregate = try await AllPornStreamResolver(
                    fetch: { requestedURL, headers in
                        if requestedURL == url {
                            return HTTPPage(body: html, finalURL: url, statusCode: 200)
                        }
                        return try await resolver.pageFetch(requestedURL, headers)
                    },
                    providerResolver: resolver
                ).resolve(postURL: url)
            }
            let state = !aggregate.resolution.qualities.isEmpty
                ? "resolved"
                : aggregate.attempts.contains(where: { $0.outcome == .verificationRequired })
                    ? "verificationRequired"
                    : "noProviderResolved"
            return ExtractionResult(
                sourcePageURL: url,
                isDirectMedia: false,
                resolutionState: state,
                trace: aggregate.resolution.trace,
                resolution: aggregate.resolution,
                providerAttempts: aggregate.attempts
            )
        } catch AllPornStreamVerificationError.verificationRequired {
            return verificationRequired(url: url)
        } catch let error as BrowserCaptureError {
            return ExtractionResult(
                sourcePageURL: url,
                isDirectMedia: false,
                resolutionState: "verificationRequired",
                trace: [error.localizedDescription],
                providerAttempts: []
            )
        } catch {
            return ExtractionResult(
                sourcePageURL: url,
                isDirectMedia: false,
                resolutionState: "staticResolutionFailed",
                trace: ["AllPornStream post resolution failed: \(error.localizedDescription)"],
                providerAttempts: []
            )
        }
    }

    private func verificationRequired(url: URL) -> ExtractionResult {
        ExtractionResult(
            sourcePageURL: url,
            isDirectMedia: false,
            resolutionState: "verificationRequired",
            trace: ["AllPornStream requires interactive browser verification."],
            providerAttempts: []
        )
    }
}
