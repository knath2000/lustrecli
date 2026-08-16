import Foundation

public enum AgentClientError: Error, LocalizedError {
    case agentNotRunning
    case invalidResponse
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .agentNotRunning: "The Lustre Agent is not running. Start it with `lustre-agent`."
        case .invalidResponse: "The Lustre Agent returned an invalid response."
        case .server(let message): message
        }
    }
}

public struct AgentClient {
    private let endpoint: AgentEndpoint
    private let token: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() throws {
        guard let data = try? Data(contentsOf: AgentPaths.endpoint),
              let endpoint = try? JSONDecoder().decode(AgentEndpoint.self, from: data) else {
            throw AgentClientError.agentNotRunning
        }
        self.endpoint = endpoint
        self.token = try KeychainTokenStore.token()
    }

    public func jobs() async throws -> [DownloadJob] {
        try await request(path: "/v1/jobs", method: "GET", body: Optional<Data>.none)
    }

    public func googleDriveDestinations() async throws -> [GoogleDriveDestinationProfile] {
        try await request(path: "/v1/destinations/google-drive", method: "GET", body: Optional<Data>.none)
    }

    public func connectGoogleDrive(remoteName: String?) async throws -> GoogleDriveDestinationProfile {
        try await request(path: "/v1/destinations/google-drive/connect", method: "POST", body: try encoder.encode(["remoteName": remoteName]))
    }

    public func selectGoogleDriveFolder(profileID: UUID, path: String) async throws -> GoogleDriveDestinationProfile {
        try await request(path: "/v1/destinations/google-drive/\(profileID.uuidString)/select", method: "POST", body: try encoder.encode(["path": path]))
    }

    public func feedSites() async throws -> [FeedSite] {
        try await request(path: "/v1/feed/sites", method: "GET", body: Optional<Data>.none)
    }

    public func feedPage(site: FeedSiteID, query: String? = nil, page: Int = 1) async throws -> FeedPage {
        let feedQuery = try FeedQuery(site: site, text: query, page: page)
        var components = URLComponents(string: "http://127.0.0.1:\(endpoint.port)/v1/feed/items")!
        components.queryItems = [URLQueryItem(name: "site", value: feedQuery.site.rawValue), URLQueryItem(name: "page", value: String(feedQuery.page))] + (feedQuery.text.map { [URLQueryItem(name: "q", value: $0)] } ?? [])
        guard let url = components.url else { throw AgentClientError.invalidResponse }
        return try await request(url: url, method: "GET", body: Optional<Data>.none)
    }

    public func verifyAllPornStream() async throws {
        let _: EmptyAgentResponse = try await request(path: "/v1/feed/verify/allpornstream", method: "POST", body: Optional<Data>.none)
    }

    public func pornHubAuthStatus() async throws -> PornHubAuthStatus {
        try await request(path: "/v1/auth/pornhub", method: "GET", body: Optional<Data>.none)
    }

    public func signInWithPornHub() async throws -> PornHubAuthStatus {
        try await request(path: "/v1/auth/pornhub/login", method: "POST", body: Optional<Data>.none)
    }

    public func cancelPornHubSignIn() async throws -> PornHubAuthStatus {
        try await request(path: "/v1/auth/pornhub/login", method: "DELETE", body: Optional<Data>.none)
    }

    public func signOutOfPornHub() async throws -> PornHubAuthStatus {
        try await request(path: "/v1/auth/pornhub", method: "DELETE", body: Optional<Data>.none)
    }

    public func extract(url: URL) async throws -> ExtractionResult {
        try await request(path: "/v1/extract", method: "POST", body: try encoder.encode(["url": url.absoluteString]))
    }

    public func queue(_ input: CreateJobRequest) async throws -> DownloadJob {
        try await request(path: "/v1/jobs", method: "POST", body: try encoder.encode(input))
    }

    public func apply(_ action: JobAction, to id: UUID) async throws -> DownloadJob {
        try await request(path: "/v1/jobs/\(id.uuidString)/action", method: "POST", body: try encoder.encode(["action": action.rawValue]))
    }

    public func removeJob(id: UUID) async throws {
        let _: EmptyAgentResponse = try await request(path: "/v1/jobs/\(id.uuidString)", method: "DELETE", body: Optional<Data>.none)
    }

    private func request<T: Decodable>(path: String, method: String, body: Data?) async throws -> T {
        try await request(url: URL(string: "http://127.0.0.1:\(endpoint.port)\(path)")!, method: method, body: body)
    }

    private func request<T: Decodable>(url: URL, method: String, body: Data?) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(ErrorResponse.self, from: data).error) ?? "Agent request failed with HTTP \(http.statusCode)."
            throw AgentClientError.server(message)
        }
        return try decoder.decode(T.self, from: data)
    }
}

public struct ErrorResponse: Codable, Sendable {
    public let error: String

    public init(error: String) {
        self.error = error
    }
}

public struct EmptyAgentResponse: Codable, Sendable {
    public init() {}
}
