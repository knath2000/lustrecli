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

public struct ProviderHTTPRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
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
    public typealias RequestFetch = @Sendable (ProviderHTTPRequest) async throws -> HTTPPage

    public let pageFetch: Fetch
    let requestFetch: RequestFetch
    private let randomSuffix: @Sendable () -> String
    private let nowMilliseconds: @Sendable () -> String

    public init() {
        self.init(requestFetch: Self.fetchRequest, randomSuffix: Self.makeRandomSuffix, nowMilliseconds: Self.currentMilliseconds)
    }

    public init(
        fetch: @escaping Fetch,
        randomSuffix: @escaping @Sendable () -> String,
        nowMilliseconds: @escaping @Sendable () -> String
    ) {
        self.pageFetch = fetch
        self.requestFetch = { request in
            guard request.method == "GET", request.body == nil else {
                throw ProviderResolverError.network("The injected provider transport does not support request bodies.")
            }
            return try await fetch(request.url, request.headers)
        }
        self.randomSuffix = randomSuffix
        self.nowMilliseconds = nowMilliseconds
    }

    public init(
        requestFetch: @escaping RequestFetch
    ) {
        self.init(requestFetch: requestFetch, randomSuffix: Self.makeRandomSuffix, nowMilliseconds: Self.currentMilliseconds)
    }

    public init(
        requestFetch: @escaping RequestFetch,
        randomSuffix: @escaping @Sendable () -> String,
        nowMilliseconds: @escaping @Sendable () -> String
    ) {
        self.requestFetch = requestFetch
        self.pageFetch = { url, headers in
            try await requestFetch(ProviderHTTPRequest(url: url, headers: headers))
        }
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
        if trustedProvider == .hqPorner || Self.isHQPornerSourceURL(url) {
            guard Self.isHQPornerSourceURL(url) else { throw ProviderResolverError.invalidURL }
            return try await resolveHQPorner(url: url)
        }
        if trustedProvider == .pmvHaven || Self.isPMVHavenSourceURL(url) {
            guard Self.isPMVHavenSourceURL(url) else { throw ProviderResolverError.invalidURL }
            return try await resolvePMVHaven(url: url)
        }
        if trustedProvider == .doodStream || isDoodHost(url.host) {
            return try await resolveDood(url: url, forcePlaymogo: trustedProvider == .doodStream)
        }
        if trustedProvider == .vidara || isExactHost(url.host, domains: ["vidara.so"]) {
            return try await resolveVidara(url: url)
        }
        if trustedProvider == .luluStream || isExactHost(url.host, domains: ["luluvid.com", "luluvdo.com", "lulustream.com"]) {
            return try await resolveLulu(url: url)
        }
        if isMyDaddyHost(url.host) {
            return try await resolveMyDaddy(url: url)
        }
        if trustedProvider == .mixDrop || isMixDropHost(url.host) {
            return try await resolveMixDrop(url: url)
        }
        if trustedProvider == .streamTape || isStreamTapeHost(url.host) {
            return try await resolveStreamTape(url: url)
        }
        throw ProviderResolverError.unsupportedProvider
    }

    private func resolvePMVHaven(url: URL) async throws -> ProviderResolution {
        let page = try await fetchProviderPage(url, headers: htmlHeaders(referer: nil))
        guard Self.isPMVHavenHost(page.finalURL.host), page.finalURL.scheme?.lowercased() == "https" else {
            throw ProviderResolverError.invalidURL
        }
        let html = normalizePMVHaven(page.body)
        let headers = [
            "Referer": "https://pmvhaven.com/",
            "User-Agent": NetworkConstants.chromeUserAgent
        ]
        let qualities = pmvHavenSources(in: html).map {
            ResolvedQuality(
                label: $0.label,
                url: $0.url,
                headers: headers,
                resolutionMethod: "Static PMVHaven page resolver",
                mediaKind: $0.url.pathExtension.lowercased() == "m3u8" ? .hls : .direct
            )
        }
        guard !qualities.isEmpty else { throw ProviderResolverError.noMediaFound }
        return ProviderResolution(
            sourcePageURL: url,
            provider: .pmvHaven,
            title: pmvHavenTitle(in: html, pageURL: url),
            thumbnailURL: imageURL(in: html, relativeTo: page.finalURL),
            qualities: qualities,
            trace: [
                "Fetched PMVHaven video page.",
                "Resolved \(qualities.count) target media source\(qualities.count == 1 ? "" : "s") with required CDN request headers."
            ]
        )
    }

    func resolveMyDaddy(url: URL) async throws -> ProviderResolution {
        let referer = URL(string: "https://hqporner.com/")!
        let page = try await fetchProviderPage(url, headers: htmlHeaders(referer: referer))
        guard isMyDaddyHost(page.finalURL.host), page.finalURL.scheme?.lowercased() == "https" else {
            throw ProviderResolverError.invalidURL
        }
        let html = normalize(page.body)
            .replacingOccurrences(of: #"\""#, with: "\"")
        let headers = [
            "Referer": page.finalURL.absoluteString,
            "User-Agent": NetworkConstants.chromeUserAgent
        ]
        let qualities = myDaddySources(in: html, relativeTo: page.finalURL).map {
            ResolvedQuality(
                label: $0.label,
                url: $0.url,
                headers: headers,
                resolutionMethod: "Static mydaddy source resolver"
            )
        }
        guard !qualities.isEmpty else { throw ProviderResolverError.noMediaFound }
        return ProviderResolution(
            sourcePageURL: url,
            provider: .myDaddy,
            title: title(in: html) ?? "mydaddy Video",
            qualities: qualities,
            trace: [
                "Fetched \(page.finalURL.host ?? "mydaddy") static embed with HQPorner referer.",
                "Resolved \(qualities.count) unique media source\(qualities.count == 1 ? "" : "s") from HTML source tags."
            ]
        )
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
        let mirrorURL = mixDropFallbackMirrorURL(for: url)
        var pages = [(url, false)]
        if let mirrorURL { pages.append((mirrorURL, true)) }
        var diagnostics: [String] = []
        var errors: [ProviderResolverError] = []
        for (pageURL, usedFallbackMirror) in pages {
            do {
                let page = try await fetchProviderPage(pageURL, headers: htmlHeaders(referer: nil))
                if let resolution = mixDropResolution(from: page, requestedURL: url, usedFallbackMirror: usedFallbackMirror) {
                    return resolution
                }
                diagnostics.append("Static \(page.finalURL.host ?? pageURL.host ?? "MixDrop") page exposed no usable media URL.")
            } catch let error as ProviderResolverError {
                errors.append(error)
                diagnostics.append("Static \(pageURL.host ?? "MixDrop") request failed: \(error.localizedDescription)")
            } catch {
                diagnostics.append("Static \(pageURL.host ?? "MixDrop") request failed: \(error.localizedDescription)")
            }
        }
        if errors.contains(where: { if case .invalidURL = $0 { true } else { false } }) {
            throw ProviderResolverError.invalidURL
        }
        if errors.contains(where: { if case .cloudflareChallenge = $0 { true } else { false } }) {
            throw ProviderResolverError.cloudflareChallenge
        }
        if errors.isEmpty || errors.contains(where: { if case .noMediaFound = $0 { true } else { false } }) {
            throw ProviderResolverError.noMediaFound
        }
        throw ProviderResolverError.network(diagnostics.joined(separator: " "))
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
        let candidates = streamTapeCandidates(in: html, relativeTo: page.finalURL)
        guard !candidates.isEmpty else {
            throw ProviderResolverError.network(streamTapeCandidateFailure(in: html))
        }

        var mediaURL: URL?
        var failures: [String] = []
        for candidate in candidates {
            if isTapeContentMediaURL(candidate) {
                mediaURL = candidate
                break
            }
            do {
                mediaURL = try await resolveStreamTapeRedirect(candidate, referer: page.finalURL)
                break
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        guard let mediaURL else {
            throw ProviderResolverError.network(
                failures.last ?? "StreamTape token response did not redirect to approved media."
            )
        }
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

    private func resolveStreamTapeRedirect(_ candidate: URL, referer: URL) async throws -> URL {
        guard isStreamTapeGetVideoURL(candidate) else {
            throw ProviderResolverError.network("StreamTape candidate used a rejected host or path.")
        }
        let requestURL = streamTapeStreamingURL(candidate)
        let headers = mediaHeaders(referer: referer)

        do {
            return try await probeStreamTapeRedirect(
                ProviderHTTPRequest(url: requestURL, method: "HEAD", headers: headers)
            )
        } catch {
            var rangedHeaders = headers
            rangedHeaders["Range"] = "bytes=0-0"
            do {
                return try await probeStreamTapeRedirect(
                    ProviderHTTPRequest(url: requestURL, headers: rangedHeaders)
                )
            } catch {
                throw ProviderResolverError.network("StreamTape redirect failed: \(error.localizedDescription)")
            }
        }
    }

    private func probeStreamTapeRedirect(_ request: ProviderHTTPRequest) async throws -> URL {
        guard URLSafetyPolicy.isAllowed(request.url) else { throw ProviderResolverError.invalidURL }
        let page = try await requestFetch(request)
        guard (200...299).contains(page.statusCode) else {
            throw ProviderResolverError.network("StreamTape token request returned HTTP \(page.statusCode).")
        }
        guard URLSafetyPolicy.isAllowed(page.finalURL), isTapeContentMediaURL(page.finalURL) else {
            if page.finalURL == request.url {
                throw ProviderResolverError.network("StreamTape token response did not redirect to media.")
            }
            throw ProviderResolverError.network("StreamTape redirect resolved to a rejected host.")
        }
        return page.finalURL
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
        try await fetchRequest(ProviderHTTPRequest(url: url, headers: headers))
    }

    private static func fetchRequest(_ providerRequest: ProviderHTTPRequest) async throws -> HTTPPage {
        let url = providerRequest.url
        guard URLSafetyPolicy.isAllowed(url) else { throw ProviderResolverError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = providerRequest.method
        request.httpBody = providerRequest.body
        request.timeoutInterval = 20
        providerRequest.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let redirectDelegate = SafeRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  URLSafetyPolicy.isAllowed(http.url ?? url) else {
                throw ProviderResolverError.network("Provider returned an invalid response.")
            }
            let isProbe = providerRequest.method == "HEAD" || providerRequest.headers["Range"] == "bytes=0-0"
            guard isProbe || String(data: data, encoding: .utf8) != nil else {
                throw ProviderResolverError.network("Provider returned an invalid response.")
            }
            let body = isProbe ? "" : String(data: data, encoding: .utf8)!
            return HTTPPage(body: body, finalURL: http.url ?? url, statusCode: http.statusCode)
        } catch let error as ProviderResolverError {
            throw error
        } catch {
            throw ProviderResolverError.network(transportDiagnostic(error))
        }
    }

    func checkedRequest(_ request: ProviderHTTPRequest) async throws -> HTTPPage {
        guard URLSafetyPolicy.isAllowed(request.url) else { throw ProviderResolverError.invalidURL }
        let page = try await requestFetch(request)
        guard URLSafetyPolicy.isAllowed(page.finalURL) else { throw ProviderResolverError.invalidURL }
        if isCloudflareChallenge(page) { throw ProviderResolverError.cloudflareChallenge }
        guard (200...299).contains(page.statusCode) else {
            throw ProviderResolverError.network("Provider returned HTTP \(page.statusCode).")
        }
        return page
    }

    func isExactHost(_ host: String?, domains: [String]) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public static func isHQPornerHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "hqporner.com" || host.hasSuffix(".hqporner.com")
    }

    public static func isHQPornerSourceURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", isHQPornerHost(url.host) else { return false }
        return url.path.range(of: #"^/hdporn/\d+(?:[-/][^/?#]*)?$"#, options: .regularExpression) != nil
    }

    public static func isPMVHavenHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "pmvhaven.com" || host.hasSuffix(".pmvhaven.com")
    }

    public static func isPMVHavenSourceURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", isPMVHavenHost(url.host) else { return false }
        return url.path.hasPrefix("/video/") || url.path.hasPrefix("/videos/")
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
              url.user == nil, url.password == nil,
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

private func isMyDaddyHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    return host == "mydaddy.cc" || host.hasSuffix(".mydaddy.cc")
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
    return host == "streamtape.com" || host == "streamtape.net" || host == "streamta.pe"
        || host.hasSuffix(".streamtape.com") || host.hasSuffix(".streamtape.net") || host.hasSuffix(".streamta.pe")
}

private func isCloudAtaMediaURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased(), (host == "cloudatacdn.com" || host.hasSuffix(".cloudatacdn.com")), url.path.contains("~") else { return false }
    let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
    return names.contains("token") && names.contains("expiry")
}

func isCloudflareChallenge(_ page: HTTPPage) -> Bool {
    page.statusCode == 403 && (page.body.localizedCaseInsensitiveContains("cf-mitigated") || page.body.localizedCaseInsensitiveContains("just a moment"))
}

private func transportDiagnostic(_ error: Error) -> String {
    let error = error as NSError
    guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
    switch error.code {
    case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
        return "DNS lookup failed before the provider could be reached."
    case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
        return "TLS negotiation failed before the provider returned an HTTP response. The current network route may be incompatible with this provider."
    case NSURLErrorTimedOut:
        return "The provider request timed out before an HTTP response was received."
    default:
        return error.localizedDescription
    }
}

private func normalize(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\/", with: "/")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&#038;", with: "&")
        .replacingOccurrences(of: "&quot;", with: "\"")
}

private func normalizePMVHaven(_ value: String) -> String {
    normalize(value)
        .replacingOccurrences(of: "\\u002F", with: "/", options: .caseInsensitive)
        .replacingOccurrences(of: "\\u003A", with: ":", options: .caseInsensitive)
        .replacingOccurrences(of: "\\u0026", with: "&", options: .caseInsensitive)
}

private func pmvHavenSources(in html: String) -> [(label: String, url: URL)] {
    guard let regex = try? NSRegularExpression(
        pattern: #"https?://[^"'\s<>\\]+\.(?:mp4|m3u8)(?:\?[^"'\s<>\\]+)?"#,
        options: [.caseInsensitive]
    ) else { return [] }
    var urls: [URL] = []
    var seen = Set<String>()
    for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
        guard let range = Range(match.range, in: html),
              let url = URL(string: String(html[range])),
              URLSafetyPolicy.isAllowed(url),
              seen.insert(url.absoluteString).inserted else { continue }
        urls.append(url)
    }
    guard let master = urls.first(where: { $0.lastPathComponent.lowercased() == "master.m3u8" }) else { return [] }
    let directory = master.deletingLastPathComponent()
    let target = urls.filter {
        $0.deletingLastPathComponent() == directory
            && !$0.path.lowercased().contains("/videopreview/")
    }
    return target.sorted {
        let leftMP4 = $0.pathExtension.lowercased() == "mp4"
        let rightMP4 = $1.pathExtension.lowercased() == "mp4"
        if leftMP4 != rightMP4 { return leftMP4 }
        let leftMaster = $0.lastPathComponent.lowercased() == "master.m3u8"
        let rightMaster = $1.lastPathComponent.lowercased() == "master.m3u8"
        if leftMaster != rightMaster { return !leftMaster }
        return resolutionHeight(in: $0.lastPathComponent) > resolutionHeight(in: $1.lastPathComponent)
    }.map {
        let filename = $0.lastPathComponent.lowercased()
        let label: String
        if $0.pathExtension.lowercased() == "mp4" {
            label = "MP4"
        } else if filename == "master.m3u8" {
            label = "Master HLS"
        } else {
            let height = resolutionHeight(in: filename)
            label = height > 0 ? "\(height)p" : "HLS"
        }
        return (label, $0)
    }
}

private func pmvHavenTitle(in html: String, pageURL: URL) -> String? {
    let raw = firstMatch([
        #"<meta[^>]+(?:property|name)=["'](?:og:title|twitter:title)["'][^>]+content=["']([^"']+)"#,
        #"<title[^>]*>(.+?)</title>"#
    ], in: html) ?? pageURL.lastPathComponent
    var value = raw
        .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    for suffix in [" - PMVHaven", " | PMVHaven", " – PMVHaven", " — PMVHaven"] where value.lowercased().hasSuffix(suffix.lowercased()) {
        value.removeLast(suffix.count)
        break
    }
    if value == pageURL.lastPathComponent,
       let range = value.range(of: #"_[0-9a-f]{24}$"#, options: [.regularExpression, .caseInsensitive]) {
        value.removeSubrange(range)
        value = value.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    }
    return value.isEmpty ? nil : value
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

private func myDaddySources(in html: String, relativeTo pageURL: URL) -> [(label: String, url: URL)] {
    guard let tagRegex = try? NSRegularExpression(pattern: #"<source\b[^>]*>"#, options: [.caseInsensitive]),
          let attributeRegex = try? NSRegularExpression(
            pattern: #"\b(src|title|label)\s*=\s*(["'])(.*?)\2"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
          ) else {
        return []
    }
    var sources: [(label: String, url: URL, index: Int)] = []
    var seen = Set<String>()
    let tags = tagRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
    for (index, tagMatch) in tags.enumerated() {
        guard let tagRange = Range(tagMatch.range, in: html) else { continue }
        let tag = String(html[tagRange])
        var attributes: [String: String] = [:]
        for match in attributeRegex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let nameRange = Range(match.range(at: 1), in: tag),
                  let valueRange = Range(match.range(at: 3), in: tag) else { continue }
            attributes[String(tag[nameRange]).lowercased()] = String(tag[valueRange])
        }
        guard let rawSource = attributes["src"],
              let mediaURL = URL(string: rawSource, relativeTo: pageURL)?.absoluteURL,
              URLSafetyPolicy.isAllowed(mediaURL),
              isDirectMedia(mediaURL),
              seen.insert(mediaURL.absoluteString).inserted else {
            continue
        }
        let label = attributes["title"] ?? attributes["label"] ?? "Video"
        sources.append((label.trimmingCharacters(in: .whitespacesAndNewlines), mediaURL, index))
    }
    return sources.sorted {
        let left = resolutionHeight(in: $0.label)
        let right = resolutionHeight(in: $1.label)
        return left == right ? $0.index < $1.index : left > right
    }.map { ($0.label.isEmpty ? "Video" : $0.label, $0.url) }
}

private func resolutionHeight(in label: String) -> Int {
    guard let regex = try? NSRegularExpression(pattern: #"(\d{3,4})\s*[pP]?"#),
          let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
          let range = Range(match.range(at: 1), in: label) else {
        return 0
    }
    return Int(label[range]) ?? 0
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

private func mixDropMediaURL(in html: String, relativeTo pageURL: URL, unpackPacked: Bool = true) -> URL? {
    let patterns = [
        #"MDCore\.wurl\s*=\s*['\"]([^'\"]+)['\"]"#,
        #"\bwurl\s*[:=]\s*['\"]([^'\"]+)['\"]"#,
        #"sources\s*:\s*\[\s*\{\s*file\s*:\s*['\"]([^'\"]+)['\"]"#,
        #"data-src\s*=\s*['\"]([^'\"]+)['\"]"#
    ]
    if let raw = firstMatch(patterns, in: html),
       let url = URL(string: raw.replacingOccurrences(of: "\\/", with: "/"), relativeTo: pageURL)?.absoluteURL,
       isMixDropMediaURL(url) {
        return url
    }
    guard unpackPacked else { return nil }
    for decoded in PackedJavaScriptDecoder.decodeAll(in: html) {
        if let url = mixDropMediaURL(in: decoded, relativeTo: pageURL, unpackPacked: false) { return url }
    }
    return nil
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

private let streamTapeLinkIDs = ["ideoolink", "botlink", "robotlink", "captchalink", "norobotlink", "ideoooolink"]

private func streamTapeCandidateFailure(in html: String) -> String {
    if html.range(of: #"document\.getElementById\(.*?\.innerHTML\s*="#, options: .regularExpression) != nil,
       html.contains("get_video") {
        return "StreamTape player assignment contained a malformed string expression."
    }
    if html.range(of: #"https?://[^\"'\s<>]+/get_video"#, options: .regularExpression) != nil {
        return "StreamTape player exposed a media candidate on a rejected host."
    }
    return "StreamTape player did not expose a trusted media link."
}

private func streamTapeCandidates(in html: String, relativeTo pageURL: URL) -> [URL] {
    var values: [(Int, String)] = []
    let assignmentPattern = #"document\.getElementById\(\s*['"]([^'"]+)['"]\s*\)\.innerHTML\s*=\s*(.*?);"#
    if let regex = try? NSRegularExpression(pattern: assignmentPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
        for (index, match) in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).enumerated() {
            guard let idRange = Range(match.range(at: 1), in: html),
                  let expressionRange = Range(match.range(at: 2), in: html) else { continue }
            let id = String(html[idRange]).lowercased()
            let expression = String(html[expressionRange])
            guard streamTapeLinkIDs.contains(id) || expression.contains("get_video"),
                  let value = evaluateStreamTapeExpression(expression) else { continue }
            values.append((streamTapeLinkIDs.firstIndex(of: id) ?? streamTapeLinkIDs.count + index, value))
        }
    }

    for (index, pattern) in [
        #"sources\s*:\s*\[\{file\s*:\s*['"]([^'"]+)['"]"#,
        #"data-src\s*=\s*['"]([^'"]+)['"]"#
    ].enumerated() {
        for value in allMatches(pattern, in: html) { values.append((100 + index, value)) }
    }
    for (index, id) in streamTapeLinkIDs.enumerated() {
        let pattern = #"id\s*=\s*['"]\#(NSRegularExpression.escapedPattern(for: id))['"][^>]*>(.*?)<"#
        for value in allMatches(pattern, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            values.append((200 + index, value))
        }
    }
    for value in allMatches(#"(?:video_url|url)\s*[=:]\s*['"]([^'"]+)['"]"#, in: html) {
        values.append((300, value))
    }

    var seen = Set<String>()
    return values.sorted { $0.0 < $1.0 }.compactMap { _, raw in
        guard let url = normalizeStreamTapeURL(raw, relativeTo: pageURL),
              seen.insert(url.absoluteString).inserted else { return nil }
        return url
    }
}

private func evaluateStreamTapeExpression(_ expression: String) -> String? {
    let parts = splitStreamTapeExpression(expression)
    guard !parts.isEmpty else { return nil }
    var result = ""
    for part in parts {
        guard let value = evaluateStreamTapeTerm(part) else { return nil }
        result += value
    }
    return result
}

private func splitStreamTapeExpression(_ expression: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false
    var depth = 0
    for character in expression {
        if escaped {
            current.append(character)
            escaped = false
            continue
        }
        if character == "\\", quote != nil {
            current.append(character)
            escaped = true
            continue
        }
        if character == "'" || character == "\"" {
            quote = quote == nil ? character : (quote == character ? nil : quote)
            current.append(character)
            continue
        }
        if quote == nil {
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if character == "+", depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                continue
            }
        }
        current.append(character)
    }
    let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { parts.append(tail) }
    return parts
}

private func evaluateStreamTapeTerm(_ term: String) -> String? {
    let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
    var index = text.startIndex
    func skipWhitespace() {
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
    }
    skipWhitespace()
    var wrapped = false
    if index < text.endIndex, text[index] == "(" {
        wrapped = true
        index = text.index(after: index)
        skipWhitespace()
    }
    guard index < text.endIndex, text[index] == "'" || text[index] == "\"" else { return nil }
    let quote = text[index]
    index = text.index(after: index)
    var value = ""
    var escaped = false
    var closed = false
    while index < text.endIndex {
        let character = text[index]
        index = text.index(after: index)
        if escaped {
            value.append(character)
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if character == quote {
            closed = true
            break
        } else {
            value.append(character)
        }
    }
    guard closed else { return nil }
    skipWhitespace()
    if wrapped {
        guard index < text.endIndex, text[index] == ")" else { return nil }
        index = text.index(after: index)
    }
    while true {
        skipWhitespace()
        guard index < text.endIndex else { return value }
        guard text[index...].hasPrefix(".substring(") else { return nil }
        index = text.index(index, offsetBy: ".substring(".count)
        skipWhitespace()
        let startIndex = index
        while index < text.endIndex, text[index].isNumber { index = text.index(after: index) }
        guard startIndex < index, let start = Int(text[startIndex..<index]) else { return nil }
        skipWhitespace()
        var end: Int?
        if index < text.endIndex, text[index] == "," {
            index = text.index(after: index)
            skipWhitespace()
            let endIndex = index
            while index < text.endIndex, text[index].isNumber { index = text.index(after: index) }
            guard endIndex < index, let parsed = Int(text[endIndex..<index]) else { return nil }
            end = parsed
            skipWhitespace()
        }
        guard index < text.endIndex, text[index] == ")" else { return nil }
        index = text.index(after: index)
        let characters = Array(value)
        let upper = min(end ?? characters.count, characters.count)
        value = start < upper ? String(characters[start..<upper]) : ""
    }
}

private func normalizeStreamTapeURL(_ raw: String, relativeTo pageURL: URL) -> URL? {
    let value = raw.replacingOccurrences(of: "\\/", with: "/")
        .replacingOccurrences(of: "&amp;", with: "&")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized: String
    if value.hasPrefix("https://") {
        normalized = value
    } else if value.hasPrefix("//") {
        normalized = "https:" + value
    } else if value.hasPrefix("/streamtape.com/") || value.hasPrefix("/streamtape.net/") || value.hasPrefix("/streamta.pe/") {
        normalized = "https:/" + value
    } else if value.hasPrefix("streamtape.com/") || value.hasPrefix("streamtape.net/") || value.hasPrefix("streamta.pe/") {
        normalized = "https://" + value
    } else if value.hasPrefix("/get_video") {
        normalized = "https://\(pageURL.host ?? "streamtape.com")\(value)"
    } else if value.hasPrefix("get_video") {
        normalized = "https://\(pageURL.host ?? "streamtape.com")/\(value)"
    } else {
        return nil
    }
    guard let url = URL(string: normalized), url.scheme == "https",
          isStreamTapeGetVideoURL(url) || isTapeContentMediaURL(url) else { return nil }
    return isStreamTapeGetVideoURL(url) ? streamTapeStreamingURL(url) : url
}

private func streamTapeStreamingURL(_ url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    var items = components.queryItems ?? []
    if !items.contains(where: { $0.name == "stream" }) {
        items.append(URLQueryItem(name: "stream", value: "1"))
    }
    components.queryItems = items
    return components.url ?? url
}

private func isStreamTapeGetVideoURL(_ url: URL) -> Bool {
    isStreamTapeHost(url.host) && url.scheme?.lowercased() == "https" && url.path.contains("/get_video")
}

private func isTapeContentMediaURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
    return (host == "tapecontent.net" || host.hasSuffix(".tapecontent.net"))
        && url.path.lowercased().contains(".mp4")
}

private func allMatches(
    _ pattern: String,
    in text: String,
    options: NSRegularExpression.Options = [.caseInsensitive]
) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
        guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
