import Foundation

public enum FeedSiteID: String, Codable, CaseIterable, Sendable {
    case allPornStream = "allpornstream"
    case hqPorner = "hqporner"
    case onlyFan420 = "onlyfan420"
    case pornHub = "pornhub"
    case pornHubSubscriptions = "pornhub-subscriptions"
    case pornHubLiked = "pornhub-liked"
    case pornHubFavorites = "pornhub-favorites"
}

public enum FeedQueueCapability: String, Codable, Sendable {
    case supported
}

public struct FeedQuery: Equatable, Sendable {
    public let site: FeedSiteID
    public let text: String?
    public let page: Int

    public init(site: FeedSiteID, text: String? = nil, page: Int = 1) throws {
        guard page > 0 else { throw FeedError.invalidPage }
        guard text?.rangeOfCharacter(from: .controlCharacters) == nil else { throw FeedError.invalidQuery }
        let normalized = text?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard
              normalized?.count ?? 0 <= 120 else { throw FeedError.invalidQuery }
        self.site = site
        self.text = normalized?.isEmpty == true ? nil : normalized
        self.page = page
    }
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
        supportsSearch: true
    )

    public static let onlyFan420 = FeedSite(
        id: .onlyFan420,
        displayName: "OnlyFan420",
        homeURL: URL(string: "https://rentry.co/OnlyFan420")!,
        supportsSearch: false
    )

    public static let hqPorner = FeedSite(
        id: .hqPorner,
        displayName: "HQPorner",
        homeURL: URL(string: "https://hqporner.com")!,
        supportsSearch: true
    )

    public static let pornHub = FeedSite(
        id: .pornHub,
        displayName: "PornHub",
        homeURL: URL(string: "https://www.pornhub.com")!,
        supportsSearch: true
    )

    public static let pornHubSubscriptions = FeedSite(id: .pornHubSubscriptions, displayName: "PornHub · Subscriptions", homeURL: URL(string: "https://www.pornhub.com/subscriptions")!, supportsSearch: false)
    public static let pornHubLiked = FeedSite(id: .pornHubLiked, displayName: "PornHub · Liked", homeURL: URL(string: "https://www.pornhub.com/likedvideos")!, supportsSearch: false)
    public static let pornHubFavorites = FeedSite(id: .pornHubFavorites, displayName: "PornHub · Favorites", homeURL: URL(string: "https://www.pornhub.com/users/favorites")!, supportsSearch: false)

    public static let authenticatedPornHub: [FeedSite] = [.pornHubSubscriptions, .pornHubLiked, .pornHubFavorites]
    public static let all: [FeedSite] = [.allPornStream, .hqPorner, .onlyFan420, .pornHub]
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

public enum PornHubHomepageSession: Equatable, Sendable {
    case anonymous
    case authenticated(cookieHeader: String)
}

public enum FeedError: Error, LocalizedError, Equatable, Sendable {
    case invalidPage
    case invalidQuery
    case unsupportedSite
    case missingStructuredData
    case invalidStructuredData
    case challengeRequired
    case authenticationRequired
    case authenticationUnavailable
    case network(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidPage: "Feed pages must be positive integers."
        case .invalidQuery: "Feed searches must be plain text no longer than 120 characters."
        case .unsupportedSite: "This feed source is not supported."
        case .missingStructuredData: "The feed page did not include video metadata."
        case .invalidStructuredData: "The feed metadata could not be decoded."
        case .challengeRequired: "PornHub returned a login, age, region, or anti-bot challenge; anonymous feed access is temporarily unavailable."
        case .authenticationRequired: "Sign in with PornHub before using this authenticated feed."
        case .authenticationUnavailable: "PornHub session storage is unavailable."
        case .network(let status): "Feed request failed with HTTP \(status)."
        }
    }
}

public struct FeedService: Sendable {
    public typealias Fetch = StaticProviderResolver.Fetch
    public typealias CookieHeader = @Sendable (URL) async throws -> String?
    public typealias HomepageSession = @Sendable (URL) async throws -> PornHubHomepageSession
    public typealias AllPornStreamHTML = @Sendable (URL) async throws -> String

    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let pornHubCookieHeader: CookieHeader?
    private let pornHubHomepageSession: HomepageSession?
    private let allPornStreamHTML: AllPornStreamHTML?

    public init(fetch: @escaping Fetch = StaticProviderResolver().pageFetch, now: @escaping @Sendable () -> Date = { .now }, pornHubCookieHeader: CookieHeader? = nil, pornHubHomepageSession: HomepageSession? = nil, allPornStreamHTML: AllPornStreamHTML? = nil) {
        self.fetch = fetch
        self.now = now
        self.pornHubCookieHeader = pornHubCookieHeader
        self.pornHubHomepageSession = pornHubHomepageSession
        self.allPornStreamHTML = allPornStreamHTML
    }

    public func sites() -> [FeedSite] {
        FeedSite.all
    }

    public func page(site: FeedSiteID, page: Int) async throws -> FeedPage {
        try await self.page(FeedQuery(site: site, page: page))
    }

    public func page(_ query: FeedQuery) async throws -> FeedPage {
        let site = query.site
        let page = query.page
        if let url = try pornHubURL(site: site, text: query.text, page: page) {
            var headers = [
                "User-Agent": NetworkConstants.chromeUserAgent,
                "Referer": "https://www.pornhub.com/",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9"
            ]
            if site == .pornHub, let pornHubHomepageSession {
                switch try await pornHubHomepageSession(url) {
                case .anonymous:
                    break
                case .authenticated(let cookieHeader):
                    guard !cookieHeader.isEmpty else { throw FeedError.authenticationUnavailable }
                    headers["Cookie"] = cookieHeader
                }
            } else if site != .pornHub {
                guard let pornHubCookieHeader, let cookie = try await pornHubCookieHeader(url), !cookie.isEmpty else { throw FeedError.authenticationRequired }
                headers["Cookie"] = cookie
            }
            let response = try await fetch(url, headers)
            guard PornHubFeedParser.isAllowedHost(response.finalURL.host),
                  response.finalURL.scheme?.lowercased() == "https" else {
                throw ProviderResolverError.invalidURL
            }
            guard (200...299).contains(response.statusCode) else { throw FeedError.network(response.statusCode) }
            let parsed = try PornHubFeedParser.parse(html: response.body, page: page, now: now())
            return FeedPage(items: parsed.items.map { item in
                FeedItem(id: "\(site.rawValue):\(item.id)", siteID: site, title: item.title, sourcePageURL: item.sourcePageURL, thumbnailURL: item.thumbnailURL, previewURLs: item.previewURLs, uploadedAt: item.uploadedAt, uploadedAtIsApproximate: item.uploadedAtIsApproximate, viewCount: item.viewCount, studio: item.studio, queueCapability: item.queueCapability)
            }, page: parsed.page, hasMore: parsed.hasMore)
        }
        if site == .hqPorner {
            let url = try hqPornerURL(query)
            let response = try await fetch(url, [
                "User-Agent": NetworkConstants.chromeUserAgent,
                "Referer": "https://hqporner.com/",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9"
            ])
            guard StaticProviderResolver.isHQPornerHost(response.finalURL.host),
                  response.finalURL.scheme?.lowercased() == "https" else {
                throw ProviderResolverError.invalidURL
            }
            guard (200...299).contains(response.statusCode) else { throw FeedError.network(response.statusCode) }
            return HQPornerFeedParser.parse(html: response.body, page: page, now: now())
        }
        if site == .onlyFan420 {
            let baseURL = FeedSite.onlyFan420.homeURL
            let response = try await fetch(baseURL, [
                "User-Agent": NetworkConstants.chromeUserAgent,
                "Referer": "https://rentry.co",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9"
            ])
            guard URLSafetyPolicy.isAllowed(response.finalURL) else { throw ProviderResolverError.invalidURL }
            guard (200...299).contains(response.statusCode) else { throw FeedError.network(response.statusCode) }
            return OnlyFan420FeedParser.parse(html: response.body, page: page)
        }
        guard site == .allPornStream else { throw FeedError.unsupportedSite }
        let baseURL = FeedSite.allPornStream.homeURL
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []
        if let text = query.text { items.append(URLQueryItem(name: "search", value: text)) }
        if page > 1 { items.append(URLQueryItem(name: "page", value: String(page))) }
        components?.queryItems = items.isEmpty ? nil : items
        guard let url = components?.url else { throw FeedError.invalidPage }
        if let allPornStreamHTML {
            return try AllPornStreamFeedParser.parse(html: try await allPornStreamHTML(url), page: page, baseURL: baseURL)
        }
        let response = try await fetch(url, [
            "User-Agent": NetworkConstants.chromeUserAgent,
            "Referer": baseURL.absoluteString,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9"
        ])
        guard (200...299).contains(response.statusCode) else { throw FeedError.network(response.statusCode) }
        return try AllPornStreamFeedParser.parse(html: response.body, page: page, baseURL: baseURL)
    }

    private func pornHubURL(site: FeedSiteID, text: String?, page: Int) throws -> URL? {
        switch site {
        case .pornHub: return try text.map { try PornHubFeedParser.searchURL(query: $0, page: page) } ?? PornHubFeedParser.pageURL(page: page)
        case .pornHubSubscriptions: return pagedPornHubURL("https://www.pornhub.com/subscriptions", page: page)
        case .pornHubLiked: return pagedPornHubURL("https://www.pornhub.com/likedvideos", page: page)
        case .pornHubFavorites: return pagedPornHubURL("https://www.pornhub.com/users/favorites", page: page)
        default: return nil
        }
    }

    private func hqPornerURL(_ query: FeedQuery) throws -> URL {
        guard var components = URLComponents(url: FeedSite.hqPorner.homeURL, resolvingAgainstBaseURL: false) else { throw FeedError.invalidPage }
        guard let text = query.text else { return try HQPornerFeedParser.pageURL(page: query.page) }
        var items = [URLQueryItem(name: "q", value: text)]
        if query.page > 1 { items.append(URLQueryItem(name: "p", value: String(query.page))) }
        components.queryItems = items
        guard let url = components.url else { throw FeedError.invalidPage }
        return url
    }

    private func pagedPornHubURL(_ raw: String, page: Int) -> URL? {
        guard var components = URLComponents(string: raw) else { return nil }
        if page > 1 { components.queryItems = [URLQueryItem(name: "page", value: String(page))] }
        return components.url
    }
}

public enum OnlyFan420FeedParser {
    private static let hosts = ["luluvid.com", "luluvdo.com", "lulustream.com", "vidara.so", "playmogo.com", "doodstream.com", "dood.wf"]
    public static let pageSize = 50

    public static func parse(html: String, page: Int = 1) -> FeedPage {
        guard page > 0 else { return FeedPage(items: [], page: page, hasMore: false) }
        let datePattern = #"<span[^>]*color\s*:\s*yellow[^>]*>(\d{1,2}\s+[A-Za-z]+\s+\d{4})\s*--"#
        guard let dateRegex = try? NSRegularExpression(pattern: datePattern, options: [.caseInsensitive]) else {
            return FeedPage(items: [], page: page, hasMore: false)
        }
        let dateMatches = dateRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var items: [FeedItem] = []
        var seen = Set<String>()
        for (index, match) in dateMatches.enumerated() {
            guard let rawDateRange = Range(match.range(at: 1), in: html),
                  let matchRange = Range(match.range, in: html),
                  let date = parseDate(String(html[rawDateRange])) else { continue }
            let end = index + 1 < dateMatches.count
                ? Range(dateMatches[index + 1].range, in: html)!.lowerBound
                : html.endIndex
            let section = String(html[matchRange.upperBound..<end])
            items.append(contentsOf: parseLinks(section, date: date, seen: &seen))
        }
        let start = (page - 1) * pageSize
        guard start < items.count else { return FeedPage(items: [], page: page, hasMore: false) }
        let end = min(start + pageSize, items.count)
        return FeedPage(items: Array(items[start..<end]), page: page, hasMore: end < items.count)
    }

    private static func parseLinks(_ section: String, date: Date, seen: inout Set<String>) -> [FeedItem] {
        let pattern = #"<a\b(?=[^>]*\bclass\s*=\s*["'][^"']*\bexternal\b[^"']*["'])(?=[^>]*\bhref\s*=\s*["']([^"']+)["'])[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: section, range: NSRange(section.startIndex..., in: section)).compactMap { match in
            guard let hrefRange = Range(match.range(at: 1), in: section),
                  let innerRange = Range(match.range(at: 2), in: section),
                  let url = URL(string: decode(String(section[hrefRange]))),
                  URLSafetyPolicy.isAllowed(url),
                  isAllowedHost(url.host),
                  seen.insert(url.absoluteString).inserted else { return nil }
            let inner = String(section[innerRange])
            guard let image = first(#"<img[^>]+\bsrc\s*=\s*["']([^"']+)["']"#, inner).flatMap({ URL(string: decode($0), relativeTo: FeedSite.onlyFan420.homeURL)?.absoluteURL }),
                  URLSafetyPolicy.isAllowed(image) else { return nil }
            let beforeImage = inner.range(of: "<img", options: .caseInsensitive).map { String(inner[..<$0.lowerBound]) } ?? inner
            let title = decode(beforeImage.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let host = url.host!.lowercased()
            let component = url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
            return FeedItem(
                id: "\(host):\(component)", siteID: .onlyFan420, title: title,
                sourcePageURL: url, thumbnailURL: image, previewURLs: [], uploadedAt: date,
                viewCount: 0, studio: studio(title), queueCapability: .supported
            )
        }
    }

    private static func isAllowedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func parseDate(_ value: String) -> Date? {
        for format in ["d MMMM yyyy", "d MMM yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return Calendar(identifier: .gregorian).date(bySettingHour: 12, minute: 0, second: 0, of: date)
            }
        }
        return nil
    }

    private static func first(_ pattern: String, _ value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func studio(_ title: String) -> String? {
        guard let separator = title.range(of: " - ") else { return nil }
        let value = title[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
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
