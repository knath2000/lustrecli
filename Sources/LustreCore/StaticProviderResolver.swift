import Foundation
import Network

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

    public let pageFetch: Fetch
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
        self.pageFetch = fetch
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
        let initialPage = try await fetchProviderPage(url, headers: htmlHeaders(referer: nil))
        if let resolution = mixDropResolution(from: initialPage, requestedURL: url, usedFallbackMirror: false) {
            return resolution
        }
        if let mirrorURL = mixDropFallbackMirrorURL(for: initialPage.finalURL) {
            let mirrorPage = try await fetchProviderPage(mirrorURL, headers: htmlHeaders(referer: nil))
            if let resolution = mixDropResolution(from: mirrorPage, requestedURL: url, usedFallbackMirror: true) {
                return resolution
            }
        }
        throw ProviderResolverError.noMediaFound
    }

    private func mixDropResolution(from page: HTTPPage, requestedURL: URL, usedFallbackMirror: Bool) -> ProviderResolution? {
        let html = normalize(page.body)
        guard let mediaURL = mixDropMediaURL(in: html, relativeTo: page.finalURL) else { return nil }
        let headers = ["User-Agent": NetworkConstants.chromeUserAgent, "Referer": page.finalURL.absoluteString]
        var trace = ["Fetched \(page.finalURL.host ?? "MixDrop") static page."]
        if usedFallbackMirror { trace.append("Fetched current MixDrop fallback mirror.") }
        trace.append("Resolved static MixDrop media configuration.")
        return ProviderResolution(
            sourcePageURL: requestedURL,
            provider: .mixDrop,
            title: title(in: html) ?? "MixDrop Video",
            thumbnailURL: imageURL(in: html, relativeTo: page.finalURL),
            qualities: [ResolvedQuality(label: "Video", url: mediaURL, headers: headers, resolutionMethod: "Static MixDrop resolver")],
            trace: trace
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
        guard URLSafetyPolicy.isAllowed(url) else { throw ProviderResolverError.invalidURL }
        let page = try await pageFetch(url, headers)
        guard URLSafetyPolicy.isAllowed(page.finalURL) else { throw ProviderResolverError.invalidURL }
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
        guard URLSafetyPolicy.isAllowed(url) else { throw ProviderResolverError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let redirectDelegate = SafeRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  URLSafetyPolicy.isAllowed(http.url ?? url),
                  let body = String(data: data, encoding: .utf8) else {
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
        if let address = IPv4Address(host) {
            return !isDisallowedIPv4(Array(address.rawValue))
        }
        if let address = IPv6Address(host) {
            return !isDisallowedIPv6(Array(address.rawValue))
        }
        return true
    }

    private static func isDisallowedIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return true }
        return bytes[0] == 0 || bytes[0] == 10 || bytes[0] == 127
            || (bytes[0] == 100 && (64...127).contains(bytes[1]))
            || (bytes[0] == 169 && bytes[1] == 254)
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 198 && (18...19).contains(bytes[1]))
    }

    private static func isDisallowedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) || (bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1) {
            return true
        }
        if bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) {
            return true
        }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return isDisallowedIPv4(Array(bytes.suffix(4)))
        }
        return false
    }
}

private final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url ?? task.originalRequest?.url ?? response.url else {
            completionHandler(nil)
            return
        }
        completionHandler(URLSafetyPolicy.isAllowed(redirectURL) ? request : nil)
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

private func mixDropFallbackMirrorURL(for url: URL) -> URL? {
    guard let host = url.host?.lowercased(), host != "miiiixdrop.net", host != "www.miiiixdrop.net",
          let fileCode = url.path.split(separator: "/").last, !fileCode.isEmpty,
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return nil
    }
    components.scheme = "https"
    components.host = "miiiixdrop.net"
    components.path = "/f/\(fileCode)"
    components.query = nil
    components.fragment = nil
    return components.url
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
    return isMixDropMediaURL(url) ? url : nil
}

private func isMixDropMediaURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased(), host == "mxcontent.net" || host.hasSuffix(".mxcontent.net") else {
        return false
    }
    let path = url.path.lowercased()
    if path.contains(".mp4") { return true }
    let segments = path.split(separator: "/", omittingEmptySubsequences: true)
    return segments.count >= 3 && segments[0] == "d" && !segments[1].isEmpty && !segments[2].isEmpty
}

private func streamTapeCandidate(in html: String, relativeTo pageURL: URL) -> URL? {
    let patterns = [
        #"sources\s*:\s*\[\{file\s*:\s*['\"]([^'\"]+)['\"]"#,
        #"data-src\s*=\s*['\"]([^'\"]+)['\"]"#,
        #"(?:video_url|url)\s*[=:]\s*['\"]([^'\"]*/get_video[^'\"]*)['\"]"#,
        #"(https?://[^\"'\s<>]*streamtape[^\"'\s<>]*/get_video[^\"'\s<>]*)"#
    ]
    guard let raw = firstMatch(patterns, in: html) else { return nil }
    return URL(string: raw.replacingOccurrences(of: "\\/", with: "/"), relativeTo: pageURL)?.absoluteURL
}

private func isStreamTapeMediaURL(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    return host == "tapecontent.net" || host.hasSuffix(".tapecontent.net")
        || host == "streamtape.com" || host == "streamtape.net" || host == "streamta.pe"
        || host.hasSuffix(".streamtape.com") || host.hasSuffix(".streamtape.net") || host.hasSuffix(".streamta.pe")
}
