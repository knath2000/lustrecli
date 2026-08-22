import Foundation
import LustreCore

public struct CloudExtractionClient: Sendable {
    private let identity: DeviceIdentity
    private let session: URLSession

    public init(identity: DeviceIdentity = DeviceIdentity(), session: URLSession? = nil) {
        self.identity = identity
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public func extract(url: URL) async throws -> ExtractionResult {
        try await withThrowingTaskGroup(of: ExtractionResult.self) { group in
            group.addTask { try await extractWithinDeadline(url: url) }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw CloudExtractionError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CloudExtractionError.invalidResponse
            }
            return result
        }
    }

    private func extractWithinDeadline(url: URL) async throws -> ExtractionResult {
        guard let enrollment = try DeviceEnrollmentStore.load() else {
            throw CloudExtractionError.notEnrolled
        }
        let origin = try validatedOrigin(enrollment.cloudOrigin)
        let enrollmentClient = try CloudEnrollmentClient(origin: origin)
        let challenge = try await enrollmentClient.deviceSessionChallenge(deviceID: enrollment.deviceID)
        let envelope = try CloudDeviceProtocol.envelope(
            purpose: "session",
            audience: enrollment.cloudOrigin,
            subjectID: enrollment.deviceID.uuidString.lowercased(),
            nonce: challenge.nonce,
            thumbprint: try identity.thumbprint(),
            expiresAt: challenge.expiresAt
        )
        let completion = try await enrollmentClient.completeDeviceSession(
            deviceID: enrollment.deviceID,
            challengeID: challenge.challengeID,
            signature: try identity.sign(envelope)
        )

        var request = URLRequest(url: origin.appending(path: "api/cloud/v1/resolve"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(completion.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(ResolveRequest(sourcePageURL: url))

        let (data, response) = try await session.data(for: request)
        guard data.count <= 131_072, let http = response as? HTTPURLResponse else {
            throw CloudExtractionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error.code) ?? "request_failed"
            throw CloudExtractionError.server(code)
        }
        let cloud = try JSONDecoder().decode(CloudResolution.self, from: data)
        return try cloud.extractionResult(requestedURL: url)
    }

    private func validatedOrigin(_ value: String) throws -> URL {
        guard let origin = URL(string: value),
              origin.scheme == "https" || (origin.scheme == "http" && origin.host == "localhost"),
              origin.host != nil,
              origin.user == nil,
              origin.password == nil
        else {
            throw CloudExtractionError.invalidResponse
        }
        return origin
    }

    private struct ResolveRequest: Encodable {
        let sourcePageURL: URL
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }
}

public enum CloudExtractionError: Error, LocalizedError, Sendable {
    case notEnrolled
    case timedOut
    case invalidResponse
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .notEnrolled: "Lustre Cloud is not paired."
        case .timedOut: "Lustre Cloud extraction timed out."
        case .invalidResponse: "Lustre Cloud returned an invalid extraction response."
        case .server(let code): "Lustre Cloud extraction failed (\(code))."
        }
    }
}

private struct CloudResolution: Decodable {
    let sourcePageURL: URL
    let title: String
    let thumbnailURL: URL?
    let qualities: [Quality]

    struct Quality: Decodable {
        let label: String
        let url: URL
        let mediaKind: String
        let headers: [String: String]
        let provider: String?
        let resolutionMethod: String?
        let stagingToken: String?
    }

    func extractionResult(requestedURL: URL) throws -> ExtractionResult {
        guard sourcePageURL == requestedURL, !qualities.isEmpty else {
            throw CloudExtractionError.invalidResponse
        }
        let resolved = try qualities.map { quality -> ResolvedQuality in
            guard URLSafetyPolicy.isAllowed(quality.url)
            else {
                throw CloudExtractionError.invalidResponse
            }
            let mediaKind: MediaKind
            switch quality.mediaKind {
            case "video": mediaKind = .direct
            case "hls": mediaKind = .hls
            default: throw CloudExtractionError.invalidResponse
            }
            return ResolvedQuality(
                label: quality.label,
                url: quality.url,
                headers: quality.headers,
                resolutionMethod: quality.resolutionMethod.map { "Lustre Cloud · \($0)" } ?? "Lustre Cloud",
                mediaKind: mediaKind,
                cloudStagingToken: quality.stagingToken
            )
        }
        let provider = providerKind(qualities.first?.provider)
        let resolution = ProviderResolution(
            sourcePageURL: sourcePageURL,
            provider: provider,
            title: title,
            thumbnailURL: thumbnailURL,
            qualities: resolved,
            trace: ["Resolved by Lustre Cloud."]
        )
        return ExtractionResult(
            sourcePageURL: sourcePageURL,
            isDirectMedia: false,
            resolutionState: "resolved",
            trace: resolution.trace,
            resolution: resolution,
            providerAttempts: [
                ProviderAttempt(providerName: "Lustre Cloud", sourceURL: sourcePageURL, outcome: .resolved, resolutionMethod: "cloud")
            ]
        )
    }

    private func providerKind(_ value: String?) -> ProviderKind {
        switch value?.lowercased() {
        case "allpornstream": .allPornStream
        case "hqporner": .hqPorner
        case "doodstream", "playmogo": .doodStream
        case "mixdrop": .mixDrop
        case "streamtape": .streamTape
        case "luluvdo", "lulustream": .luluStream
        case "vidara": .vidara
        case "pornhub": .pornHub
        case "yt-dlp": .ytDlp
        default: .direct
        }
    }
}
