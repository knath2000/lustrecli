import Foundation

public enum HQPornerFeedParser {
    private static let baseURL = URL(string: "https://hqporner.com")!

    public static func pageURL(page: Int) throws -> URL {
        guard page > 0 else { throw FeedError.invalidPage }
        return page == 1 ? baseURL : baseURL.appending(path: "hdporn/\(page)")
    }

    public static func parse(html: String, page: Int, now: Date) -> FeedPage {
        guard page > 0 else { return FeedPage(items: [], page: page, hasMore: false) }
        var items: [FeedItem] = []
        var seen = Set<String>()
        for segment in cardSegments(in: html) {
            guard let rawPath = first(#"\bhref\s*=\s*["']([^"']*/hdporn/[^"']+)["']"#, in: segment),
                  let sourceURL = canonicalSourceURL(rawPath),
                  let id = first(#"^/hdporn/(\d+)(?:[-/]|$)"#, in: sourceURL.path),
                  seen.insert(sourceURL.absoluteString).inserted else {
                continue
            }
            let title = cardTitle(in: segment)
            guard !title.isEmpty else { continue }
            items.append(FeedItem(
                id: "hqporner-\(id)",
                siteID: .hqPorner,
                title: title,
                sourcePageURL: sourceURL,
                thumbnailURL: firstImage(in: segment),
                previewURLs: previewURLs(in: segment),
                uploadedAt: now,
                uploadedAtIsApproximate: true,
                viewCount: 0,
                studio: nil,
                queueCapability: .supported
            ))
        }
        return FeedPage(items: items, page: page, hasMore: !items.isEmpty)
    }

    private static func cardSegments(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<section\b(?=[^>]*\bclass\s*=\s*["'][^"']*(?:\bbox\b[^"']*\bfeature\b|\bfeature\b[^"']*\bbox\b)[^"']*["'])[^>]*>.*?</section>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range, in: html).map { String(html[$0]) }
        }
    }

    private static func canonicalSourceURL(_ raw: String) -> URL? {
        guard let url = safeHTTPSURL(raw, relativeTo: baseURL),
              StaticProviderResolver.isHQPornerSourceURL(url) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        components?.host = "hqporner.com"
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    private static func cardTitle(in segment: String) -> String {
        if let value = first(#"<h3\b[^>]*\bclass\s*=\s*["'][^"']*\bmeta-data-title\b[^"']*["'][^>]*>.*?<a\b[^>]*>(.*?)</a>"#, in: segment) {
            return cleanText(value)
        }
        return first(#"<img\b[^>]*\balt\s*=\s*["']([^"']+)["']"#, in: segment).map(cleanText) ?? ""
    }

    private static func firstImage(in segment: String) -> URL? {
        let patterns = [
            #"<img\b(?=[^>]*\bid\s*=\s*["']cover_\d+["'])[^>]*\bsrc\s*=\s*["']([^"']+)["']"#,
            #"<img\b(?=[^>]*\bsrc\s*=\s*["']([^"']+)["'])[^>]*\bid\s*=\s*["']cover_\d+["']"#
        ]
        for pattern in patterns {
            if let raw = first(pattern, in: segment), let url = safeHTTPSURL(decode(raw), relativeTo: baseURL) {
                return url
            }
        }
        return nil
    }

    private static func previewURLs(in segment: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"changeImage\(\s*["']([^"']+)["']"#, options: [.caseInsensitive]) else {
            return []
        }
        var result: [URL] = []
        var seen = Set<String>()
        for match in regex.matches(in: segment, range: NSRange(segment.startIndex..., in: segment)) {
            guard result.count < 4,
                  let range = Range(match.range(at: 1), in: segment),
                  let url = safeHTTPSURL(decode(String(segment[range])), relativeTo: baseURL),
                  seen.insert(url.absoluteString).inserted else { continue }
            result.append(url)
        }
        return result
    }

    private static func safeHTTPSURL(_ raw: String, relativeTo baseURL: URL) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = value.hasPrefix("//") ? "https:\(value)" : value
        guard let url = URL(string: normalized, relativeTo: baseURL)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              URLSafetyPolicy.isAllowed(url) else { return nil }
        return url
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func cleanText(_ value: String) -> String {
        decode(value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
