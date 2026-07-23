import Foundation

public enum FeedSiteID: String, Codable, CaseIterable, Sendable {
    case allPornStream = "allpornstream"
}

public enum FeedQueueCapability: String, Codable, Sendable {
    case supported
}

public struct FeedSite: Codable, Equatable, Identifiable, Sendable {
    public let id: FeedSiteID
    public let displayName: String
    public let homeURL: URL
    public let supportsSearch: Bool

    public init(id: FeedSiteID, displayName: String, homeURL: URL, supportsSearch: Bool) {
        self.id = id
        self.displayName = displayName
        self.homeURL = homeURL
        self.supportsSearch = supportsSearch
    }

    public static let allPornStream = FeedSite(
        id: .allPornStream,
        displayName: "AllPornStream",
        homeURL: URL(string: "https://allpornstream.com")!,
        supportsSearch: false
    )

    public static let all: [FeedSite] = [.allPornStream]
}

public struct FeedItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let siteID: FeedSiteID
    public let title: String
    public let sourcePageURL: URL
    public let thumbnailURL: URL?
    public let previewURLs: [URL]
    public let uploadedAt: Date
    public let uploadedAtIsApproximate: Bool
    public let viewCount: Int
    public let studio: String?
    public let queueCapability: FeedQueueCapability

    public init(
        id: String,
        siteID: FeedSiteID,
        title: String,
        sourcePageURL: URL,
        thumbnailURL: URL?,
        previewURLs: [URL],
        uploadedAt: Date,
        uploadedAtIsApproximate: Bool = false,
        viewCount: Int,
        studio: String?,
        queueCapability: FeedQueueCapability
    ) {
        self.id = id
        self.siteID = siteID
        self.title = title
        self.sourcePageURL = sourcePageURL
        self.thumbnailURL = thumbnailURL
        self.previewURLs = previewURLs
        self.uploadedAt = uploadedAt
        self.uploadedAtIsApproximate = uploadedAtIsApproximate
        self.viewCount = viewCount
        self.studio = studio
        self.queueCapability = queueCapability
    }
}

public struct FeedPage: Codable, Equatable, Sendable {
    public let items: [FeedItem]
    public let page: Int
    public let hasMore: Bool

    public init(items: [FeedItem], page: Int, hasMore: Bool) {
        self.items = items
        self.page = page
        self.hasMore = hasMore
    }
}

public enum FeedError: Error, LocalizedError, Equatable, Sendable {
    case invalidPage
    case unsupportedSite
    case missingStructuredData
    case invalidStructuredData
    case network(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidPage: "Feed pages must be positive integers."
        case .unsupportedSite: "This feed source is not supported."
        case .missingStructuredData: "The feed page did not include video metadata."
        case .invalidStructuredData: "The feed metadata could not be decoded."
        case .network(let status): "Feed request failed with HTTP \(status)."
        }
    }
}

public struct FeedService: Sendable {
    public typealias Fetch = StaticProviderResolver.Fetch

    private let fetch: Fetch

    public init(fetch: @escaping Fetch = StaticProviderResolver().pageFetch) {
        self.fetch = fetch
    }

    public func sites() -> [FeedSite] {
        FeedSite.all
    }

    public func page(site: FeedSiteID, page: Int) async throws -> FeedPage {
        guard page > 0 else { throw FeedError.invalidPage }
        guard site == .allPornStream else { throw FeedError.unsupportedSite }
        let baseURL = FeedSite.allPornStream.homeURL
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        if page > 1 {
            components?.queryItems = [URLQueryItem(name: "page", value: String(page))]
        }
        guard let url = components?.url else { throw FeedError.invalidPage }
        let response = try await fetch(url, [
            "User-Agent": NetworkConstants.chromeUserAgent,
            "Referer": baseURL.absoluteString,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9"
        ])
        guard (200...299).contains(response.statusCode) else { throw FeedError.network(response.statusCode) }
        return try AllPornStreamFeedParser.parse(html: response.body, page: page, baseURL: baseURL)
    }
}

public enum AllPornStreamFeedParser {
    public static func parse(html: String, page: Int, baseURL: URL = FeedSite.allPornStream.homeURL) throws -> FeedPage {
        guard page > 0 else { throw FeedError.invalidPage }
        let scripts = matches(
            pattern: #"<script[^>]+type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>"#,
            in: html,
            options: [.caseInsensitive, .dotMatchesLineSeparators],
            capture: 1
        )
        guard let script = scripts.first(where: { $0.contains("ItemList") && $0.contains("VideoObject") }) else {
            throw FeedError.missingStructuredData
        }
        guard let data = script.data(using: .utf8),
              let list = try? JSONDecoder().decode(ItemList.self, from: data) else {
            throw FeedError.invalidStructuredData
        }
        let items = list.itemListElement.compactMap { video -> FeedItem? in
            guard let uploadedAt = iso8601Date(video.uploadDate),
                  let sourcePageURL = URL(string: video.url, relativeTo: baseURL)?.absoluteURL,
                  let id = postID(sourcePageURL) else { return nil }
            let previewURLs = cardImages(for: video.url, html: html, baseURL: baseURL)
            let fallbackThumbnail = video.thumbnailURLs.first.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
            let thumbnail = previewURLs.first ?? fallbackThumbnail.flatMap { proxiedImageURL($0, baseURL: baseURL) }
            return FeedItem(
                id: id,
                siteID: .allPornStream,
                title: video.name,
                sourcePageURL: sourcePageURL,
                thumbnailURL: thumbnail,
                previewURLs: previewURLs,
                uploadedAt: uploadedAt,
                viewCount: video.interactionStatistic?.userInteractionCount.value ?? 0,
                studio: studio(from: video.name),
                queueCapability: .supported
            )
        }
        return FeedPage(items: items, page: page, hasMore: !items.isEmpty)
    }

    private struct ItemList: Decodable {
        let itemListElement: [VideoObject]
    }

    private struct VideoObject: Decodable {
        let name: String
        let url: String
        let thumbnailURLs: [String]
        let uploadDate: String
        let interactionStatistic: InteractionStatistic?

        enum CodingKeys: String, CodingKey {
            case name, url, uploadDate, interactionStatistic
            case thumbnailURLs = "thumbnailUrl"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            url = try container.decode(String.self, forKey: .url)
            uploadDate = try container.decode(String.self, forKey: .uploadDate)
            interactionStatistic = try container.decodeIfPresent(InteractionStatistic.self, forKey: .interactionStatistic)
            if let values = try? container.decode([String].self, forKey: .thumbnailURLs) {
                thumbnailURLs = values
            } else if let value = try? container.decode(String.self, forKey: .thumbnailURLs) {
                thumbnailURLs = [value]
            } else {
                thumbnailURLs = []
            }
        }
    }

    private struct InteractionStatistic: Decodable {
        let userInteractionCount: FlexibleInteger
    }

    private struct FlexibleInteger: Decodable {
        let value: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let integer = try? container.decode(Int.self) {
                value = integer
            } else if let string = try? container.decode(String.self), let integer = Int(string) {
                value = integer
            } else {
                value = 0
            }
        }
    }

    private static func postID(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "post"), parts.indices.contains(index + 1) else { return nil }
        return parts[index + 1]
    }

    private static func studio(from title: String) -> String? {
        guard let range = title.range(of: #"^\[([^\]]+)\]"#, options: .regularExpression) else { return nil }
        let value = title[range].dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func iso8601Date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func cardImages(for relativeURL: String, html: String, baseURL: URL) -> [URL] {
        let tokens = ["data-href=\"\(relativeURL)\"", "data-slug=\"\(relativeURL)\""]
        guard let token = tokens.compactMap({ html.range(of: $0) }).first else { return [] }
        let end = html.range(of: "data-href=", range: token.upperBound..<html.endIndex)?.lowerBound ?? html.endIndex
        let segment = String(html[token.lowerBound..<end])
        let decoded = decodeHTMLEntities(segment)
        let direct = matches(
            pattern: #"https://[^\"'\s,&<>\]]+\.(?:jpg|jpeg|png|webp)(?:\?[^\"'\s,&<>\]]*)?"#,
            in: decoded
        )
        var seen = Set<String>()
        return direct.compactMap { raw in
            guard let source = URL(string: raw), let proxied = proxiedImageURL(source, baseURL: baseURL), seen.insert(proxied.absoluteString).inserted else {
                return nil
            }
            return proxied
        }
    }

    private static func proxiedImageURL(_ source: URL, baseURL: URL) -> URL? {
        if source.host == baseURL.host, source.path == "/api/images" { return source }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/images"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "src", value: source.absoluteString),
            URLQueryItem(name: "width", value: "384"),
            URLQueryItem(name: "quality", value: "60")
        ]
        return components?.url
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func matches(
        pattern: String,
        in value: String,
        options: NSRegularExpression.Options = [],
        capture: Int = 0
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > capture, let range = Range(match.range(at: capture), in: value) else { return nil }
            return String(value[range])
        }
    }
}
