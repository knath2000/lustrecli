import Foundation

public struct HTTPPage: Sendable {
    public let body: String
    public let finalURL: URL
    public let statusCode: Int

    public init(body: String, finalURL: URL, statusCode: Int) {
        self.body = body
        self.finalURL = finalURL
        self.statusCode = statusCode
    }
}

public enum ProviderResolverError: Error, LocalizedError, Sendable {
    case invalidURL
    case unsupportedProvider
    case noMediaFound
    case cloudflareChallenge
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Only public HTTP(S) URLs are allowed."
        case .unsupportedProvider: "No static resolver is installed for this provider."
        case .noMediaFound: "The provider page did not expose a usable media URL."
        case .cloudflareChallenge: "The provider requires interactive browser verification."
        case .network(let message): message
        }
    }
}

public struct StaticProviderResolver: Sendable {
    public typealias Fetch = @Sendable (URL, [String: String]) async throws -> HTTPPage

    private let fetch: Fetch
    private let randomSuffix: @Sendable () -> String
    private let nowMilliseconds: @Sendable () -> String

    public init() {
        self.init(fetch: Self.fetchPage, randomSuffix: Self.makeRandomSuffix, nowMilliseconds: Self.currentMilliseconds)
    }

    public init(
        fetch: @escaping Fetch,
        randomSuffix: @escaping @Sendable () -> String,
        nowMilliseconds: @escaping @Sendable () -> String
    ) {
        self.fetch = fetch
        self.randomSuffix = randomSuffix
        self.nowMilliseconds = nowMilliseconds
    }

    public func resolve(url: URL, trustedProvider: ProviderKind? = nil) async throws -> ProviderResolution {
        guard URLSafetyPolicy.isAllowed(url) else { throw ProviderResolverError.invalidURL }
        if isDirectMedia(url) {
            return ProviderResolution(
                sourcePageURL: url,
                provider: .direct,
                qualities: [ResolvedQuality(label: "Video", url: url, resolutionMethod: "Direct media URL")],
                trace: ["Accepted direct media URL."]
            )
        }
        if trustedProvider == .doodStream || isDoodHost(url.host) {
            return try await resolveDood(url: url, forcePlaymogo: trustedProvider == .doodStream)
        }
        if trustedProvider == .mixDrop || isMixDropHost(url.host) {
            return try await resolveMixDrop(url: url)
        }
        if trustedProvider == .streamTape || isStreamTapeHost(url.host) {
            return try await resolveStreamTape(url: url)
        }
        throw ProviderResolverError.unsupportedProvider
    }

    private func resolveDood(url: URL, forcePlaymogo: Bool) async throws -> ProviderResolution {
        let requestedURL = canonicalPlaymogoURL(for: url, force: forcePlaymogo)
        var page = try await fetchProviderPage(requestedURL, headers: htmlHeaders(referer: nil))
        if page.finalURL.path.hasPrefix("/d/"), let embedURL = embeddedPlayerURL(in: page.body, relativeTo: page.finalURL) {
            page = try await fetchProviderPage(embedURL, headers: htmlHeaders(referer: page.finalURL))
        }

        let pageURL = page.finalURL
        let isPlaymogo = isPlaymogoHost(pageURL.host)
        let html = normalize(page.body)
        let title = title(in: html) ?? (isPlaymogo ? "Playmogo Video" : "DoodStream Video")
        let thumbnail = imageURL(in: html, relativeTo: pageURL)
        var trace = ["Fetched \(pageURL.host ?? "provider") static page."]

        if isPlaymogo {
            guard let passPath = firstMatch([
                #"\.get\(\s*['\"]([^'\"]*/pass_md5/[^'\"]+)['\"]"#,
                #"\burl\s*:\s*['\"]([^'\"]*/pass_md5/[^'\"]+)['\"]"#,
                #"\bfetch\(\s*['\"]([^'\"]*/pass_md5/[^'\"]+)['\"]"#,
                #"['\"]([^'\"]*/pass_md5/[^'\"]+)['\"]"#
            ], in: html),
            let passURL = URL(string: passPath, relativeTo: pageURL)?.absoluteURL,
            let tokenPrefix = firstMatch([
                #"['\"]([^'\"]*\?token=[^'\"]+&expiry=)['\"]\s*\+\s*(?:Date\s*\.\s*now\s*\(\s*\)|\(new\s+Date\s*\(\s*\)\)\.getTime\s*\(\s*\))"#,
                #"['\"]([^'\"]*\?token=[^'\"]+&expiry=)['\"]"#
            ], in: html) else {
                throw ProviderResolverError.noMediaFound
            }
            let pass = try await fetchProviderPage(passURL, headers: passHeaders(referer: pageURL))
            let mediaString = pass.body.trimmingCharacters(in: .whitespacesAndNewlines) + randomSuffix() + tokenPrefix + nowMilliseconds()
            guard let mediaURL = URL(string: mediaString), isCloudAtaMediaURL(mediaURL) else {
                throw ProviderResolverError.noMediaFound
            }
            let headers = mediaHeaders(referer: pageURL)
            trace.append("Resolved Playmogo pass_md5 URL to CloudAta media.")
            return ProviderResolution(
                sourcePageURL: url,
                provider: .doodStream,
                title: title,
                thumbnailURL: thumbnail,
                qualities: [ResolvedQuality(label: "Video", url: mediaURL, headers: headers, resolutionMethod: "Static Playmogo resolver")],
                trace: trace
            )
        }

        guard let mediaURL = doodMediaURL(in: html) else { throw ProviderResolverError.noMediaFound }
        trace.append("Resolved static Dood media configuration.")
        return ProviderResolution(
            sourcePageURL: url,
            provider: .doodStream,
            title: title,
            thumbnailURL: thumbnail,
            qualities: [ResolvedQuality(label: "Video", url: mediaURL, headers: mediaHeaders(referer: pageURL), resolutionMethod: "Static Dood resolver")],
            trace: trace
        )
    }

    private func resolveMixDrop(url: URL) async throws -> ProviderResolution {
        let page = try await fetchProviderPage(url, headers: htmlHeaders(referer: nil))
        let html = normalize(page.body)
        guard let mediaURL = mixDropMediaURL(in: html, relativeTo: page.finalURL) else {
            throw ProviderResolverError.noMediaFound
        }
        let headers = ["User-Agent": NetworkConstants.chromeUserAgent, "Referer": page.finalURL.absoluteString]
        return ProviderResolution(
            sourcePageURL: url,
            provider: .mixDrop,
            title: title(in: html) ?? "MixDrop Video",
            thumbnailURL: imageURL(in: html, relativeTo: page.finalURL),
            qualities: [ResolvedQuality(label: "Video", url: mediaURL, headers: headers, resolutionMethod: "Static MixDrop resolver")],
            trace: ["Fetched \(page.finalURL.host ?? "MixDrop") static page.", "Resolved static MixDrop media configuration."]
        )
    }

    private func resolveStreamTape(url: URL) async throws -> ProviderResolution {
        let page = try await fetchProviderPage(url, headers: htmlHeaders(referer: URL(string: "https://streamtape.com/")))
        let html = normalize(page.body)
        guard let candidate = streamTapeCandidate(in: html, relativeTo: page.finalURL) else {
            throw ProviderResolverError.noMediaFound
        }
        let mediaPage = candidate.path.contains("/get_video")
            ? try await fetchProviderPage(candidate, headers: htmlHeaders(referer: page.finalURL))
            : nil
        let mediaURL = mediaPage?.finalURL ?? candidate
        guard isStreamTapeMediaURL(mediaURL) else { throw ProviderResolverError.noMediaFound }
        let headers = ["User-Agent": NetworkConstants.chromeUserAgent, "Referer": page.finalURL.absoluteString]
        return ProviderResolution(
            sourcePageURL: url,
            provider: .streamTape,
            title: title(in: html) ?? "StreamTape Video",
            thumbnailURL: imageURL(in: html, relativeTo: page.finalURL),
            qualities: [ResolvedQuality(label: "Video", url: mediaURL, headers: headers, resolutionMethod: "Static StreamTape resolver")],
            trace: ["Fetched \(page.finalURL.host ?? "StreamTape") static page.", "Resolved static StreamTape media configuration."]
        )
    }

    private func fetchProviderPage(_ url: URL, headers: [String: String]) async throws -> HTTPPage {
        let page = try await fetch(url, headers)
        if isCloudflareChallenge(page) { throw ProviderResolverError.cloudflareChallenge }
        guard (200...299).contains(page.statusCode) else {
            throw ProviderResolverError.network("Provider returned HTTP \(page.statusCode).")
        }
        return page
    }

    private func canonicalPlaymogoURL(for url: URL, force: Bool) -> URL {
        guard let host = url.host?.lowercased(), force || host == "vide0.net" || host.hasSuffix(".vide0.net") else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        components?.host = "playmogo.com"
        return components?.url ?? url
    }

    private func htmlHeaders(referer: URL?) -> [String: String] {
        var headers = [
            "User-Agent": NetworkConstants.chromeUserAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        if let referer { headers["Referer"] = referer.absoluteString }
        return headers
    }

    private func passHeaders(referer: URL) -> [String: String] {
        [
            "User-Agent": NetworkConstants.chromeUserAgent,
            "Referer": referer.absoluteString,
            "X-Requested-With": "XMLHttpRequest",
            "Accept": "*/*"
        ]
    }

    private func mediaHeaders(referer: URL) -> [String: String] {
        [
            "Referer": referer.absoluteString,
            "User-Agent": NetworkConstants.chromeUserAgent,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9"
        ]
    }

    private static func fetchPage(url: URL, headers: [String: String]) async throws -> HTTPPage {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, let body = String(data: data, encoding: .utf8) else {
                throw ProviderResolverError.network("Provider returned an invalid response.")
            }
            return HTTPPage(body: body, finalURL: http.url ?? url, statusCode: http.statusCode)
        } catch let error as ProviderResolverError {
            throw error
        } catch {
            throw ProviderResolverError.network(error.localizedDescription)
        }
    }

    private static func makeRandomSuffix() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<10).compactMap { _ in alphabet.randomElement() })
    }

    private static func currentMilliseconds() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000))
    }
}

public enum URLSafetyPolicy {
    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              host != "localhost", !host.hasSuffix(".local"), !host.contains("%") else {
            return false
        }
        if host == "127.0.0.1" || host == "::1" || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") {
            return false
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets.count != 4 || !(octets[0] == 172 && (16...31).contains(octets[1]))
    }
}

public enum NetworkConstants {
    public static let chromeUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0"
}

private func isDirectMedia(_ url: URL) -> Bool {
    ["mp4", "m3u8", "webm", "mov"].contains(url.pathExtension.lowercased())
}

private func isDoodHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    let roots = ["doodstream.com", "doodstream.org", "dood.wf", "dood.pm", "dood.to", "dood.ws", "dood.one", "dood.watch", "dood.la", "dood.sh", "vide0.net", "dooodster.com", "playmogo.com", "ds2play.com"]
    return roots.contains { host == $0 || host.hasSuffix(".\($0)") }
}

private func isMixDropHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    let roots = ["mixdrop.ag", "mixdrop.co", "mixdrop.sx", "mixdrop.pw", "mixdrop.top", "mxdrop.to", "m1xdrop.click", "miiixdrop.net", "miiiixdrop.net"]
    return roots.contains { host == $0 || host.hasSuffix(".\($0)") }
}

private func isPlaymogoHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    return host == "playmogo.com" || host == "ds2play.com" || host.hasSuffix(".playmogo.com") || host.hasSuffix(".ds2play.com")
}

private func isStreamTapeHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    return host == "streamtape.com" || host == "streamtape.net" || host.hasSuffix(".streamtape.com") || host.hasSuffix(".streamtape.net")
}

private func isCloudAtaMediaURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased(), (host == "cloudatacdn.com" || host.hasSuffix(".cloudatacdn.com")), url.path.contains("~") else { return false }
    let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
    return names.contains("token") && names.contains("expiry")
}

private func isCloudflareChallenge(_ page: HTTPPage) -> Bool {
    page.statusCode == 403 && (page.body.localizedCaseInsensitiveContains("cf-mitigated") || page.body.localizedCaseInsensitiveContains("just a moment"))
}

private func normalize(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\/", with: "/")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&#038;", with: "&")
        .replacingOccurrences(of: "&quot;", with: "\"")
}

private func firstMatch(_ patterns: [String], in text: String) -> String? {
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { continue }
        return String(text[range])
    }
    return nil
}

private func title(in html: String) -> String? {
    firstMatch([#"<title[^>]*>(.+?)</title>"#], in: html)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func imageURL(in html: String, relativeTo pageURL: URL) -> URL? {
    guard let value = firstMatch([#"<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)"#], in: html) else { return nil }
    return URL(string: value, relativeTo: pageURL)?.absoluteURL
}

private func embeddedPlayerURL(in html: String, relativeTo pageURL: URL) -> URL? {
    guard let value = firstMatch([#"<iframe\b[^>]*\bsrc\s*=\s*[\"']([^\"']+)"#], in: html),
          let url = URL(string: value, relativeTo: pageURL)?.absoluteURL,
          url.path.hasPrefix("/e/"), URLSafetyPolicy.isAllowed(url) else { return nil }
    return url
}

private func doodMediaURL(in html: String) -> URL? {
    let patterns = [
        #"sources\s*:\s*\[\{file\s*:\s*['\"]([^'\"]+)['\"]"#,
        #"(?:download_url|downloadUrl|video_url)\s*[=:]\s*['\"]([^'\"]+)['\"]"#,
        #"(https?://[^\"'\s<>]*dood\.video[^\"'\s<>]*)"#
    ]
    guard let value = firstMatch(patterns, in: html), let url = URL(string: value) else { return nil }
    let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
    return (url.host?.contains("dood.video") == true && names.contains("token") && names.contains("expiry")) ? url : nil
}

private func mixDropMediaURL(in html: String, relativeTo pageURL: URL) -> URL? {
    let patterns = [
        #"MDCore\.wurl\s*=\s*['\"]([^'\"]+)['\"]"#,
        #"\bwurl\s*[:=]\s*['\"]([^'\"]+)['\"]"#,
        #"sources\s*:\s*\[\s*\{\s*file\s*:\s*['\"]([^'\"]+)['\"]"#,
        #"data-src\s*=\s*['\"]([^'\"]+)['\"]"#
    ]
    guard let raw = firstMatch(patterns, in: html) else { return nil }
    let normalized = raw.replacingOccurrences(of: "\\/", with: "/")
    guard let url = URL(string: normalized, relativeTo: pageURL)?.absoluteURL else { return nil }
    let host = url.host?.lowercased() ?? ""
    return host == "mxcontent.net" || host.hasSuffix(".mxcontent.net") ? url : nil
}

private func streamTapeCandidate(in html: String, relativeTo pageURL: URL) -> URL? {
    let patterns = [
        #"sources\s*:\s*\[\{file\s*:\s*['\"]([^'\"]+)['\"]"#,
        #"data-src\s*=\s*['\"]([^'\"]+)['\"]"#,
        #"(?:video_url|url)\s*[=:]\s*['\"]([^'\"]*/get_video[^'\"]*)['\"]"#
    ]
    guard let raw = firstMatch(patterns, in: html) else { return nil }
    return URL(string: raw.replacingOccurrences(of: "\\/", with: "/"), relativeTo: pageURL)?.absoluteURL
}

private func isStreamTapeMediaURL(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    return host == "streamtape.com" || host == "streamtape.net" || host == "streamta.pe" || host.hasSuffix(".streamtape.com") || host.hasSuffix(".streamtape.net") || host.hasSuffix(".streamta.pe")
}
