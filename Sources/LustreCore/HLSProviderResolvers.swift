import Foundation

extension StaticProviderResolver {
    func resolveVidara(url: URL) async throws -> ProviderResolution {
        guard let code = fileCode(url, prefixes: ["v", "e", "d"]) else { throw ProviderResolverError.invalidURL }
        let api = URL(string: "https://vidara.so/api/stream")!
        let headers = providerHeaders(referer: "https://vidara.so/")
        var apiHeaders = headers
        apiHeaders["Content-Type"] = "application/json"
        let body = try JSONSerialization.data(withJSONObject: ["filecode": code, "device": "web"], options: [.sortedKeys])
        let response = try await checkedRequest(ProviderHTTPRequest(url: api, method: "POST", headers: apiHeaders, body: body))
        guard isExactHost(response.finalURL.host, domains: ["vidara.so"]),
              let data = response.body.data(using: .utf8),
              let info = try? JSONDecoder().decode(VidaraInfo.self, from: data),
              let stream = info.streamingURL.flatMap(URL.init(string:)),
              stream.scheme?.lowercased() == "https",
              URLSafetyPolicy.isAllowed(stream) else { throw ProviderResolverError.noMediaFound }
        let qualities = try await hlsQualities(master: stream, headers: headers, method: "Vidara API + HLS")
        return ProviderResolution(
            sourcePageURL: url, provider: .vidara, title: info.title,
            thumbnailURL: info.thumbnail.flatMap(URL.init(string:)), qualities: qualities,
            trace: ["Resolved Vidara filecode through its JSON API.", "Parsed \(qualities.count) HLS quality option\(qualities.count == 1 ? "" : "s")."]
        )
    }

    func resolveLulu(url: URL) async throws -> ProviderResolution {
        guard let code = luluFileCode(url) else { throw ProviderResolverError.invalidURL }
        let wrapper = URL(string: "https://luluvid.com/d/\(code)")!
        let embed = URL(string: "https://luluvdo.com/e/\(code)")!
        let wrapperPage = try await checkedRequest(ProviderHTTPRequest(url: wrapper, headers: providerHeaders(referer: "https://luluvid.com")))
        guard isExactHost(wrapperPage.finalURL.host, domains: ["luluvid.com", "luluvdo.com", "lulustream.com"]) else {
            throw ProviderResolverError.invalidURL
        }
        let embedPage = try await checkedRequest(ProviderHTTPRequest(url: embed, headers: providerHeaders(referer: "https://luluvid.com")))
        guard isExactHost(embedPage.finalURL.host, domains: ["luluvid.com", "luluvdo.com", "lulustream.com"]),
              let raw = luluM3U8(embedPage.body),
              let master = URL(string: raw, relativeTo: embedPage.finalURL)?.absoluteURL,
              master.scheme?.lowercased() == "https",
              URLSafetyPolicy.isAllowed(master) else { throw ProviderResolverError.noMediaFound }
        let mediaHeaders = providerHeaders(referer: embed.absoluteString)
        let qualities = try await hlsQualities(master: master, headers: mediaHeaders, method: "Lulu packed player + HLS")
        return ProviderResolution(
            sourcePageURL: embed, provider: .luluStream,
            title: htmlValue(#"<title[^>]*>(.*?)</title>"#, wrapperPage.body) ?? "LuluStream Video",
            thumbnailURL: htmlValue(#"<meta[^>]+(?:property=["']og:image["'][^>]+content|content)=["']([^"']+)["']"#, wrapperPage.body).flatMap(URL.init(string:)),
            qualities: qualities,
            trace: ["Resolved Lulu wrapper metadata and embed player.", "Parsed \(qualities.count) HLS quality option\(qualities.count == 1 ? "" : "s")."]
        )
    }

    private func hlsQualities(master: URL, headers: [String: String], method: String) async throws -> [ResolvedQuality] {
        let page = try await checkedRequest(ProviderHTTPRequest(url: master, headers: headers))
        guard page.finalURL.scheme?.lowercased() == "https" else { throw ProviderResolverError.invalidURL }
        var values: [(Int, ResolvedQuality)] = []
        let lines = page.body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF") {
            guard index + 1 < lines.count,
                  let url = URL(string: lines[index + 1], relativeTo: page.finalURL)?.absoluteURL,
                  url.scheme?.lowercased() == "https", URLSafetyPolicy.isAllowed(url) else { continue }
            let height = htmlValue(#"RESOLUTION=\d+x(\d+)"#, lines[index]).flatMap(Int.init) ?? 0
            values.append((height, ResolvedQuality(
                label: height > 0 ? "\(height)p" : "stream", url: url, headers: headers,
                resolutionMethod: method, mediaKind: .hls
            )))
        }
        var seen = Set<URL>()
        let sorted = values.sorted { $0.0 > $1.0 }.compactMap { seen.insert($0.1.url).inserted ? $0.1 : nil }
        if !sorted.isEmpty { return sorted }
        return [ResolvedQuality(label: "master", url: page.finalURL, headers: headers, resolutionMethod: method, mediaKind: .hls)]
    }

    private func providerHeaders(referer: String) -> [String: String] {
        ["User-Agent": NetworkConstants.chromeUserAgent, "Referer": referer, "Accept": "*/*", "Accept-Language": "en-US,en;q=0.9"]
    }

    private func fileCode(_ url: URL, prefixes: Set<String>) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, prefixes.contains(parts[0]), safeCode(parts[1]) else { return nil }
        return parts[1]
    }

    private func luluFileCode(_ url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        let candidate: String?
        if parts.count >= 2, ["d", "e", "w"].contains(parts[parts.count - 2]) {
            candidate = parts.last
        } else {
            candidate = parts.last?.split(separator: ".").first.map(String.init)
        }
        guard let candidate, safeCode(candidate) else { return nil }
        return candidate
    }

    private func safeCode(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    private func luluM3U8(_ html: String) -> String? {
        if let direct = htmlValue(#"["'](https://[^"'\\\s]+\.m3u8[^"'\\\s]*)["']"#, html) { return direct }
        guard let packed = extractPackedBlock(html) else { return nil }
        return unpackPacker(packed).flatMap { htmlValue(#"["'](https://[^"'\\\s]+\.m3u8[^"'\\\s]*)["']"#, $0) }
    }

    private func extractPackedBlock(_ html: String) -> String? {
        guard let start = html.range(of: "eval(") else { return nil }
        let open = html.index(start.lowerBound, offsetBy: 4)
        var depth = 1
        var quote: Character?
        var escaped = false
        var index = html.index(after: open)
        while index < html.endIndex {
            let character = html[index]
            if escaped {
                escaped = false
            } else if character == "\\" && quote != nil {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = quote == nil ? character : (quote == character ? nil : quote)
            } else if quote == nil && character == "(" {
                depth += 1
            } else if quote == nil && character == ")" {
                depth -= 1
                if depth == 0 { return String(html[html.index(after: open)..<index]) }
            }
            index = html.index(after: index)
        }
        return nil
    }

    private func unpackPacker(_ packed: String) -> String? {
        let value = packed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let function = value.range(of: "function") else { return nil }
        var depth = 0
        var foundOpeningBrace = false
        var quote: Character?
        var escaped = false
        var index = function.lowerBound
        while index < value.endIndex {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "\\" && quote != nil {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = quote == nil ? character : (quote == character ? nil : quote)
            } else if quote == nil && character == "{" {
                foundOpeningBrace = true
                depth += 1
            } else if quote == nil && character == "}" {
                depth -= 1
                if foundOpeningBrace && depth == 0 {
                    return parsePackerArgs(String(value[value.index(after: index)...]))
                }
            }
            index = value.index(after: index)
        }
        return nil
    }

    private func parsePackerArgs(_ arguments: String) -> String? {
        guard let open = arguments.firstIndex(of: "(") else { return nil }
        var depth = 1
        var quote: Character?
        var escaped = false
        var index = arguments.index(after: open)
        var content = ""
        while index < arguments.endIndex && depth > 0 {
            let character = arguments[index]
            if escaped {
                escaped = false
            } else if character == "\\" && quote != nil {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = quote == nil ? character : (quote == character ? nil : quote)
            } else if quote == nil && character == "(" {
                depth += 1
            } else if quote == nil && character == ")" {
                depth -= 1
            }
            if depth > 0 { content.append(character) }
            index = arguments.index(after: index)
        }

        let parts = splitArgs(content)
        guard parts.count >= 4,
              let payload = javascriptString(parts[0]),
              let base = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"")))),
              let count = Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)),
              let dictionary = javascriptString(String(parts[3].prefix(upTo: parts[3].range(of: ".split")?.lowerBound ?? parts[3].endIndex))) else {
            return nil
        }
        return decode(payload: payload, base: base, count: count, dictionary: dictionary)
    }

    private func splitArgs(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in value {
            if escaped {
                escaped = false
            } else if character == "\\" && quote != nil {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = quote == nil ? character : (quote == character ? nil : quote)
            } else if quote == nil && character == "(" {
                depth += 1
            } else if quote == nil && character == ")" {
                depth -= 1
            } else if quote == nil && depth == 0 && character == "," {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private func javascriptString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quote = trimmed.first, quote == "'" || quote == "\"" else { return nil }
        var result = ""
        var escaped = false
        for character in trimmed.dropFirst() {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == quote {
                return result
            } else {
                result.append(character)
            }
        }
        return nil
    }

    private func decode(payload: String, base: Int, count: Int, dictionary: String) -> String? {
        guard (2...62).contains(base), count >= 0 else { return nil }
        let keys = dictionary.components(separatedBy: "|")
        var output = payload
        guard count > 0 else { return output }
        for index in stride(from: count - 1, through: 0, by: -1)
        where index < keys.count && !keys[index].isEmpty {
            let token = NSRegularExpression.escapedPattern(for: baseEncode(index, base: base))
            output = output.replacingOccurrences(
                of: #"\b\#(token)\b"#,
                with: keys[index],
                options: .regularExpression
            )
        }
        return output
    }

    private func baseEncode(_ value: Int, base: Int) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard value >= base else { return String(alphabet[value]) }
        return baseEncode(value / base, base: base) + String(alphabet[value % base])
    }

    private func htmlValue(_ pattern: String, _ value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct VidaraInfo: Decodable {
    let streamingURL: String?
    let title: String?
    let thumbnail: String?

    enum CodingKeys: String, CodingKey {
        case streamingURL = "streaming_url"
        case title, thumbnail
    }
}
