import Foundation

extension StaticProviderResolver {
    func resolveHQPorner(url: URL) async throws -> ProviderResolution {
        let referer = "https://hqporner.com/"
        let page = try await checkedRequest(ProviderHTTPRequest(url: url, headers: [
            "User-Agent": NetworkConstants.chromeUserAgent,
            "Referer": referer,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9"
        ]))
        guard Self.isHQPornerHost(page.finalURL.host),
              page.finalURL.scheme?.lowercased() == "https" else {
            throw ProviderResolverError.invalidURL
        }
        let html = page.body.replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: #"\""#, with: "\"")
        let candidates = trustedMyDaddyIframes(in: html)
        guard !candidates.isEmpty else { throw ProviderResolverError.noMediaFound }

        var failures: [String] = []
        var challengeCount = 0
        var noMediaCount = 0
        for candidate in candidates {
            do {
                let delegated = try await resolveMyDaddy(url: candidate)
                return ProviderResolution(
                    sourcePageURL: url,
                    provider: .hqPorner,
                    title: hqTitle(in: html) ?? delegated.title,
                    thumbnailURL: hqThumbnail(in: html, relativeTo: page.finalURL) ?? delegated.thumbnailURL,
                    qualities: delegated.qualities,
                    trace: [
                        "Fetched the HQPorner source page.",
                        "Delegated a trusted HQPorner embed to the mydaddy static resolver."
                    ] + delegated.trace
                )
            } catch ProviderResolverError.cloudflareChallenge {
                challengeCount += 1
                failures.append(ProviderResolverError.cloudflareChallenge.localizedDescription)
            } catch ProviderResolverError.noMediaFound {
                noMediaCount += 1
                failures.append(ProviderResolverError.noMediaFound.localizedDescription)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if challengeCount == candidates.count { throw ProviderResolverError.cloudflareChallenge }
        if noMediaCount == candidates.count { throw ProviderResolverError.noMediaFound }
        throw ProviderResolverError.network(
            "Every trusted HQPorner mydaddy embed failed: \(failures.joined(separator: "; "))"
        )
    }

    private func trustedMyDaddyIframes(in html: String) -> [URL] {
        guard let iframeRegex = try? NSRegularExpression(pattern: #"<iframe\b[^>]*>"#, options: [.caseInsensitive]),
              let sourceRegex = try? NSRegularExpression(
                pattern: #"\bsrc\s*=\s*(?:\\?["'])(.*?)(?:\\?["'])"#,
                options: [.caseInsensitive]
              ) else { return [] }
        var result: [URL] = []
        var seen = Set<String>()
        for match in iframeRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let source = sourceRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let valueRange = Range(source.range(at: 1), in: tag) else { continue }
            let raw = String(tag[valueRange]).replacingOccurrences(of: "\\/", with: "/")
            let normalized = raw.hasPrefix("//") ? "https:\(raw)" : raw
            guard let candidate = URL(string: normalized, relativeTo: URL(string: "https://hqporner.com/"))?.absoluteURL,
                  candidate.scheme?.lowercased() == "https",
                  isExactHost(candidate.host, domains: ["mydaddy.cc"]),
                  URLSafetyPolicy.isAllowed(candidate),
                  seen.insert(candidate.absoluteString).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    private func hqTitle(in html: String) -> String? {
        let patterns = [
            #"<h1\b[^>]*\bclass\s*=\s*["'][^"']*\btitle\b[^"']*["'][^>]*>(.*?)</h1>"#,
            #"<title[^>]*>(.*?)</title>"#
        ]
        for pattern in patterns {
            guard let value = hqFirst(pattern, in: html) else { continue }
            let title = hqDecode(value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
                .replacingOccurrences(of: #"\s+(?:[|-]\s*)?HQPorner.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return nil
    }

    private func hqThumbnail(in html: String, relativeTo pageURL: URL) -> URL? {
        let patterns = [
            #"<meta\b(?=[^>]*\bproperty\s*=\s*["']og:image["'])[^>]*\bcontent\s*=\s*["']([^"']+)["']"#,
            #"<meta\b(?=[^>]*\bcontent\s*=\s*["']([^"']+)["'])[^>]*\bproperty\s*=\s*["']og:image["']"#
        ]
        for pattern in patterns {
            guard let raw = hqFirst(pattern, in: html) else { continue }
            let decoded = hqDecode(raw)
            let normalized = decoded.hasPrefix("//") ? "https:\(decoded)" : decoded
            guard let url = URL(string: normalized, relativeTo: pageURL)?.absoluteURL,
                  url.scheme?.lowercased() == "https",
                  URLSafetyPolicy.isAllowed(url) else { continue }
            return url
        }
        return nil
    }

    private func hqFirst(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func hqDecode(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
