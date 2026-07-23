import Foundation

public enum PornHubFeedParser {
    private static let baseURL = URL(string: "https://www.pornhub.com")!

    public static func pageURL(page: Int) throws -> URL {
        guard page > 0 else { throw FeedError.invalidPage }
        var components = URLComponents(string: "https://www.pornhub.com/video")!
        components.queryItems = [
            URLQueryItem(name: "o", value: "ht"),
            URLQueryItem(name: "page", value: String(page))
        ]
        guard let url = components.url else { throw FeedError.invalidPage }
        return url
    }

    public static func isAllowedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "pornhub.com" || host == "www.pornhub.com" || host.hasSuffix(".pornhub.com")
    }

    public static func parse(html: String, page: Int, now: Date) throws -> FeedPage {
        guard page > 0 else { throw FeedError.invalidPage }
        let cards = matches(#"<li\b[^>]*class=["'][^"']*\bpcVideoListItem\b[^"']*["'][^>]*>.*?</li>"#, html)
        // Normal public pages contain dormant login/captcha markup. Treat challenge
        // markers as blocking only when no public listing cards were delivered.
        if cards.isEmpty, isChallenge(html) { throw FeedError.challengeRequired }
        var seen = Set<String>()
        let items = cards.compactMap { card -> FeedItem? in
            guard card.range(of: #"\b(?:advert|sponsor|premiumLocked)\b"#, options: [.regularExpression, .caseInsensitive]) == nil,
                  let rawKey = first(#"\bdata-video-vkey=["']([^"']+)["']"#, card),
                  let key = safeViewKey(decode(rawKey)),
                  seen.insert(key).inserted else { return nil }
            let titles = [
                first(#"<a\b[^>]*href=["'][^"']*view_video\.php[^"']*["'][^>]*title=["']([^"']+)["']"#, card),
                first(#"<a\b[^>]*title=["']([^"']+)["']"#, card)
            ]
            guard let title = titles.compactMap({ $0 }).map(decode).first(where: { !$0.isEmpty }) else { return nil }
            let source = URL(string: "https://www.pornhub.com/view_video.php?viewkey=\(key)")!
            let thumbnail = [
                first(#"\bdata-image=["']([^"']+)["']"#, card),
                first(#"\bdata-mediumthumb=["']([^"']+)["']"#, card),
                first(#"\bdata-src=["']([^"']+)["']"#, card),
                first(#"<img\b[^>]*\bsrc=["']([^"']+)["']"#, card)
            ].compactMap { $0 }.compactMap(safeAssetURL).first
            let previews = first(#"\bdata-mediabook=["']([^"']+)["']"#, card)
                .flatMap(safeAssetURL).map { [$0] } ?? []
            let views = first(#"\bclass=["'][^"']*\bviews\b[^"']*["'][^>]*>.*?<var[^>]*>([^<]+)</var>"#, card)
                .map(parseViews) ?? 0
            let added = first(#"<var\b[^>]*class=["'][^"']*\badded\b[^"']*["'][^>]*>([^<]+)</var>"#, card).map(decode)
            let date = added.flatMap { parseDate($0, now: now) }
            let uploader = first(#"<a\b[^>]*href=["']/(?:model|pornstar|channels|user)/[^"']+["'][^>]*>([^<]+)</a>"#, card).map(decode)
            return FeedItem(
                id: "pornhub:\(key)",
                siteID: .pornHub,
                title: title,
                sourcePageURL: source,
                thumbnailURL: thumbnail,
                previewURLs: Array(previews.prefix(4)),
                uploadedAt: date?.date ?? now,
                uploadedAtIsApproximate: date?.approximate ?? true,
                viewCount: views,
                studio: uploader,
                queueCapability: .supported
            )
        }
        let nextEvidence = html.range(of: #"(?:class=["'][^"']*(?:page_next|next)[^"']*["'][^>]*href|rel=["']next["'])"#, options: [.regularExpression, .caseInsensitive]) != nil
        return FeedPage(items: items, page: page, hasMore: nextEvidence)
    }

    public static func safeViewKey(_ raw: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard (3...128).contains(raw.count), raw.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return raw
    }

    private static func isChallenge(_ html: String) -> Bool {
        let lower = html.lowercased()
        return ["cf-chl", "just a moment", "captcha", "verify you are human", "age verification", "login to continue"]
            .contains(where: lower.contains)
    }

    private static func safeAssetURL(_ raw: String) -> URL? {
        let decoded = decode(raw)
        let value = decoded.hasPrefix("//") ? "https:\(decoded)" : decoded
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              URLSafetyPolicy.isAllowed(url) else { return nil }
        return url
    }

    private static func parseViews(_ raw: String) -> Int {
        let value = decode(raw).lowercased().replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "views", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let multiplier: Double = value.hasSuffix("m") ? 1_000_000 : value.hasSuffix("k") ? 1_000 : 1
        let number = multiplier == 1 ? value : String(value.dropLast())
        guard let parsed = Double(number), parsed.isFinite, parsed >= 0,
              parsed * multiplier <= Double(Int.max) else { return 0 }
        return Int(parsed * multiplier)
    }

    private static func parseDate(_ raw: String, now: Date) -> (date: Date, approximate: Bool)? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for format in ["MMM d, yyyy", "MMMM d, yyyy", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return (date, false) }
        }
        let pattern = #"^(\d+)\s+(minute|hour|day|week|month|year)s?\s+ago$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let countRange = Range(match.range(at: 1), in: value),
              let unitRange = Range(match.range(at: 2), in: value),
              let count = Int(value[countRange]) else { return nil }
        let component: Calendar.Component
        switch value[unitRange].lowercased() {
        case "minute": component = .minute
        case "hour": component = .hour
        case "day": component = .day
        case "week": component = .weekOfYear
        case "month": component = .month
        default: component = .year
        }
        return Calendar(identifier: .gregorian).date(byAdding: component, value: -count, to: now).map { ($0, true) }
    }

    private static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func first(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
