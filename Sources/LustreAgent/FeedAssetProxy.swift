import Foundation
import LustreCore

public enum FeedAssetKind: String, Sendable {
    case image
    case video

    var maximumBytes: Int { self == .image ? 6 * 1_024 * 1_024 : 16 * 1_024 * 1_024 }

    var accept: String { self == .image ? "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8" : "video/webm,video/mp4,video/*;q=0.9,*/*;q=0.8" }
}

public struct FeedAssetResponse: Sendable {
    public let data: Data
    public let contentType: String
    public let finalURL: URL

    public init(data: Data, contentType: String, finalURL: URL) {
        self.data = data
        self.contentType = contentType
        self.finalURL = finalURL
    }
}

public enum FeedAssetProxyError: Error, LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case unsupportedContentType
    case responseTooLarge
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The feed asset URL is not an allowed provider asset."
        case .invalidResponse: "The provider returned an invalid feed asset response."
        case .unsupportedContentType: "The provider returned an unexpected feed asset type."
        case .responseTooLarge: "The feed asset exceeded the allowed preview size."
        case .network(let message): "Unable to load feed asset: \(message)"
        }
    }
}

public struct FeedAssetProxy: Sendable {
    public typealias Fetch = @Sendable (URL, [String: String], FeedAssetKind) async throws -> FeedAssetResponse

    private let fetch: Fetch

    public init() {
        self.fetch = Self.fetch
    }

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func load(url: URL, kind: FeedAssetKind) async throws -> FeedAssetResponse {
        guard Self.isAllowed(url) else { throw FeedAssetProxyError.invalidURL }
        let response = try await fetch(url, headers(for: url, kind: kind), kind)
        guard Self.isAllowed(response.finalURL) else { throw FeedAssetProxyError.invalidURL }
        guard response.data.count <= kind.maximumBytes else { throw FeedAssetProxyError.responseTooLarge }
        guard response.contentType.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init).map({ contentType in
            kind == .image ? contentType.hasPrefix("image/") : contentType.hasPrefix("video/")
        }) == true else { throw FeedAssetProxyError.unsupportedContentType }
        return response
    }

    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", URLSafetyPolicy.isAllowed(url), let host = url.host?.lowercased() else { return false }
        return ["phncdn.com", "hqporner.com", "fastporndelivery.com"].contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private func headers(for url: URL, kind: FeedAssetKind) -> [String: String] {
        let host = url.host?.lowercased() ?? ""
        let referer = (host == "phncdn.com" || host.hasSuffix(".phncdn.com")) ? "https://www.pornhub.com/" : "https://hqporner.com/"
        return [
            "User-Agent": NetworkConstants.chromeUserAgent,
            "Referer": referer,
            "Accept": kind.accept,
            "Accept-Language": "en-US,en;q=0.9"
        ]
    }

    private static func fetch(url: URL, headers: [String: String], kind: FeedAssetKind) async throws -> FeedAssetResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let delegate = RedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, let finalURL = http.url,
                  (200...299).contains(http.statusCode), isAllowed(finalURL) else { throw FeedAssetProxyError.invalidResponse }
            if response.expectedContentLength > Int64(kind.maximumBytes) { throw FeedAssetProxyError.responseTooLarge }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            var data = Data()
            data.reserveCapacity(min(max(0, Int(response.expectedContentLength)), kind.maximumBytes))
            for try await byte in bytes {
                data.append(byte)
                if data.count > kind.maximumBytes { throw FeedAssetProxyError.responseTooLarge }
            }
            return FeedAssetResponse(data: data, contentType: contentType, finalURL: finalURL)
        } catch let error as FeedAssetProxyError {
            throw error
        } catch {
            throw FeedAssetProxyError.network(error.localizedDescription)
        }
    }
}

private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url, FeedAssetProxy.isAllowed(redirectURL) else {
            completionHandler(nil)
            return
        }
        var safeRequest = request
        safeRequest.httpShouldHandleCookies = false
        safeRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(safeRequest)
    }
}
