import Foundation

public struct AllPornStreamCandidate: Equatable, Sendable {
    public let providerName: String
    public let fileCode: String?
    public let sourceURL: URL?
    public let trustedProvider: ProviderKind?

    public init(providerName: String, fileCode: String?, sourceURL: URL?, trustedProvider: ProviderKind?) {
        self.providerName = providerName
        self.fileCode = fileCode
        self.sourceURL = sourceURL
        self.trustedProvider = trustedProvider
    }
}

public struct AllPornStreamMetadata: Equatable, Sendable {
    public let title: String?
    public let thumbnailURL: URL?
    public let candidates: [AllPornStreamCandidate]

    public init(title: String?, thumbnailURL: URL?, candidates: [AllPornStreamCandidate]) {
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.candidates = candidates
    }
}

public struct AllPornStreamResolution: Sendable {
    public let resolution: ProviderResolution
    public let attempts: [ProviderAttempt]

    public init(resolution: ProviderResolution, attempts: [ProviderAttempt]) {
        self.resolution = resolution
        self.attempts = attempts
    }
}

public struct AllPornStreamResolver: Sendable {
    private let fetch: StaticProviderResolver.Fetch
    private let providerResolver: StaticProviderResolver
    private let providerTimeout: Duration
    private let maximumConcurrentProviders: Int

    public init(
        fetch: @escaping StaticProviderResolver.Fetch,
        providerResolver: StaticProviderResolver,
        providerTimeout: Duration = .seconds(15),
        maximumConcurrentProviders: Int = 3
    ) {
        self.fetch = fetch
        self.providerResolver = providerResolver
        self.providerTimeout = providerTimeout
        self.maximumConcurrentProviders = max(1, maximumConcurrentProviders)
    }

    public static func isAllPornStreamPostURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "allpornstream.com" || host.hasSuffix(".allpornstream.com")
    }

    public static func parseMetadata(from html: String, relativeTo postURL: URL) -> AllPornStreamMetadata {
        let sources = metadataSources(in: html)
        var title: String?
        var thumbnailURL: URL?
        var records: [RawRecord] = []
        var recordIndex = 0

        for source in sources {
            for root in jsonRoots(in: source) {
                collectMetadata(
                    from: root,
                    relativeTo: postURL,
                    title: &title,
                    thumbnailURL: &thumbnailURL,
                    records: &records,
                    recordIndex: &recordIndex
                )
            }
            for value in videoURLValues(in: source) {
                collectRecords(from: value, records: &records, recordIndex: &recordIndex)
            }
            if title == nil {
                title = firstStringValue(for: ["title", "post_title", "video_title"], in: source)
            }
            if thumbnailURL == nil,
               let rawThumbnail = firstStringValue(for: ["thumbnail_url", "thumbnail", "thumbnailUrl", "image"], in: source) {
                thumbnailURL = URL(string: rawThumbnail, relativeTo: postURL)?.absoluteURL
            }
        }

        if title == nil {
            title = firstMatch([#"<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']+)"#, #"<title[^>]*>(.+?)</title>"#], in: html)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if thumbnailURL == nil,
           let rawThumbnail = firstMatch([#"<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)"#], in: html) {
            thumbnailURL = URL(string: rawThumbnail, relativeTo: postURL)?.absoluteURL
        }

        return AllPornStreamMetadata(title: title, thumbnailURL: thumbnailURL, candidates: pairedCandidates(from: records))
    }

    public func resolve(postURL: URL) async throws -> AllPornStreamResolution {
        guard URLSafetyPolicy.isAllowed(postURL) else { throw ProviderResolverError.invalidURL }
        let page = try await fetch(postURL, [
            "User-Agent": NetworkConstants.chromeUserAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9"
        ])
        let metadata = Self.parseMetadata(from: page.body, relativeTo: page.finalURL)
        let results = await resolveCandidates(metadata.candidates)
        let attempts = results.map(\.attempt)
        let qualities = results.flatMap(\.qualities)
        let trace = ["Fetched AllPornStream post metadata."]
            + (metadata.candidates.isEmpty ? ["No usable video_urls metadata was found."] : [])
            + attempts.map(traceLine(for:))
        let resolution = ProviderResolution(
            sourcePageURL: postURL,
            provider: .allPornStream,
            title: metadata.title,
            thumbnailURL: metadata.thumbnailURL,
            qualities: qualities,
            trace: trace
        )
        return AllPornStreamResolution(resolution: resolution, attempts: attempts)
    }

    private func resolveCandidates(_ candidates: [AllPornStreamCandidate]) async -> [CandidateResult] {
        var results = candidates.enumerated().map { index, candidate in
            CandidateResult(index: index, attempt: preflightAttempt(for: candidate), qualities: [])
        }
        let eligible = candidates.enumerated().filter { _, candidate in
            candidate.sourceURL != nil && candidate.trustedProvider != nil
        }
        guard !eligible.isEmpty else { return results }

        await withTaskGroup(of: CandidateResult.self) { group in
            var next = 0
            func enqueue(_ item: (offset: Int, element: AllPornStreamCandidate)) {
                group.addTask {
                    await resolveCandidate(item.element, at: item.offset)
                }
            }
            while next < min(maximumConcurrentProviders, eligible.count) {
                enqueue(eligible[next])
                next += 1
            }
            while let result = await group.next() {
                results[result.index] = result
                if next < eligible.count {
                    enqueue(eligible[next])
                    next += 1
                }
            }
        }
        return results
    }

    private func preflightAttempt(for candidate: AllPornStreamCandidate) -> ProviderAttempt {
        guard candidate.sourceURL != nil else {
            return ProviderAttempt(
                providerName: candidate.providerName,
                sourceURL: nil,
                outcome: .failed,
                reason: "The video_urls record did not contain a public link or iframe URL."
            )
        }
        guard candidate.trustedProvider != nil else {
            return ProviderAttempt(
                providerName: candidate.providerName,
                sourceURL: candidate.sourceURL,
                outcome: .failed,
                reason: "No static resolver is installed for this hosting_provider."
            )
        }
        return ProviderAttempt(providerName: candidate.providerName, sourceURL: candidate.sourceURL, outcome: .failed)
    }

    private func resolveCandidate(_ candidate: AllPornStreamCandidate, at index: Int) async -> CandidateResult {
        guard let sourceURL = candidate.sourceURL, let provider = candidate.trustedProvider else {
            return CandidateResult(index: index, attempt: preflightAttempt(for: candidate), qualities: [])
        }
        let outcome = await resolveWithStages(sourceURL: sourceURL, provider: provider)
        switch outcome {
        case .resolved(let resolution):
            let method = resolution.qualities.first?.resolutionMethod
            let qualities = resolution.qualities.map {
                ResolvedQuality(
                    label: "\(candidate.providerName) · \($0.label)",
                    url: $0.url,
                    headers: $0.headers,
                    resolutionMethod: $0.resolutionMethod
                )
            }
            guard !qualities.isEmpty else {
                return CandidateResult(
                    index: index,
                    attempt: ProviderAttempt(providerName: candidate.providerName, sourceURL: sourceURL, outcome: .failed, reason: "The provider returned no media qualities."),
                    qualities: []
                )
            }
            return CandidateResult(
                index: index,
                attempt: ProviderAttempt(providerName: candidate.providerName, sourceURL: sourceURL, outcome: .resolved, resolutionMethod: method, diagnostics: resolution.trace),
                qualities: qualities
            )
        case .verificationRequired:
            return CandidateResult(
                index: index,
                attempt: ProviderAttempt(providerName: candidate.providerName, sourceURL: sourceURL, outcome: .verificationRequired, reason: ProviderResolverError.cloudflareChallenge.localizedDescription),
                qualities: []
            )
        case .timedOut:
            return CandidateResult(
                index: index,
                attempt: ProviderAttempt(providerName: candidate.providerName, sourceURL: sourceURL, outcome: .timedOut, reason: "Static provider resolution timed out after \(providerTimeout.components.seconds) seconds."),
                qualities: []
            )
        case .failed(let reason):
            return CandidateResult(
                index: index,
                attempt: ProviderAttempt(providerName: candidate.providerName, sourceURL: sourceURL, outcome: .failed, reason: reason, diagnostics: [reason]),
                qualities: []
            )
        }
    }

    private func resolveWithStages(sourceURL: URL, provider: ProviderKind) async -> TimedResolution {
        let staticResult = await race(timeout: providerTimeout) {
            do {
                return .resolved(try await providerResolver.resolve(url: sourceURL, trustedProvider: provider))
            } catch let error as ProviderResolverError {
                if case .cloudflareChallenge = error { return .verificationRequired }
                return .failed(error.localizedDescription)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return staticResult
    }

    private func race(timeout: Duration, operation: @escaping @Sendable () async -> TimedResolution) async -> TimedResolution {
        let result = FirstStageResult<TimedResolution>()
        let operationTask = Task { await result.finish(await operation()) }
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            await result.finish(.timedOut)
        }
        let value = await result.value()
        operationTask.cancel()
        timeoutTask.cancel()
        return value
    }
}

private actor FirstStageResult<Value: Sendable> {
    private var result: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    func finish(_ value: Value) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func value() async -> Value {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result { continuation.resume(returning: result) }
            else { self.continuation = continuation }
        }
    }
}

private struct RawRecord {
    let index: Int
    let providerName: String
    let fileCode: String?
    let linkURL: URL?
    let iframeURL: URL?
}

private struct CandidateResult: Sendable {
    let index: Int
    let attempt: ProviderAttempt
    let qualities: [ResolvedQuality]
}

private enum TimedResolution: Sendable {
    case resolved(ProviderResolution)
    case verificationRequired
    case timedOut
    case failed(String)
}

private func metadataSources(in html: String) -> [String] {
    var sources = [html]
    var searchRange = html.startIndex..<html.endIndex
    let marker = "self.__next_f.push("
    while let range = html.range(of: marker, range: searchRange) {
        let start = range.upperBound
        guard let payload = balancedSegment(in: html, from: start, open: "(", close: ")", includeOpeningCharacter: false) else {
            searchRange = range.upperBound..<html.endIndex
            continue
        }
        if let data = payload.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            collectStrings(from: object, into: &sources)
        }
        searchRange = range.upperBound..<html.endIndex
    }
    return sources + sources.compactMap { source in
        let normalized = source
            .replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\/"#, with: "/")
        return normalized == source ? nil : normalized
    }
}

private func collectStrings(from value: Any, into strings: inout [String]) {
    if let string = value as? String {
        strings.append(string)
    } else if let array = value as? [Any] {
        array.forEach { collectStrings(from: $0, into: &strings) }
    } else if let dictionary = value as? [String: Any] {
        dictionary.values.forEach { collectStrings(from: $0, into: &strings) }
    }
}

private func jsonRoots(in source: String) -> [Any] {
    var roots: [Any] = []
    var index = source.startIndex
    while index < source.endIndex {
        guard source[index] == "{" || source[index] == "[" else {
            index = source.index(after: index)
            continue
        }
        let opening = source[index]
        let closing: Character = opening == "{" ? "}" : "]"
        guard let segment = balancedSegment(in: source, from: index, open: opening, close: closing, includeOpeningCharacter: true) else {
            index = source.index(after: index)
            continue
        }
        if let data = segment.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) {
            roots.append(root)
        }
        index = source.index(index, offsetBy: segment.count, limitedBy: source.endIndex) ?? source.endIndex
    }
    return roots
}

private func balancedSegment(in text: String, from start: String.Index, open: Character, close: Character, includeOpeningCharacter: Bool) -> String? {
    var index = start
    if !includeOpeningCharacter {
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        guard index < text.endIndex, text[index] == "[" || text[index] == "{" else { return nil }
        let opening = text[index]
        let closing: Character = opening == "[" ? "]" : "}"
        return balancedSegment(in: text, from: index, open: opening, close: closing, includeOpeningCharacter: true)
    }
    guard text[index] == open else { return nil }
    let segmentStart = index
    var depth = 0
    var inString = false
    var escaped = false
    while index < text.endIndex {
        let character = text[index]
        if inString {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString = false
            }
        } else if character == "\"" {
            inString = true
        } else if character == open {
            depth += 1
        } else if character == close {
            depth -= 1
            if depth == 0 {
                return String(text[segmentStart...index])
            }
        }
        index = text.index(after: index)
    }
    return nil
}

private func collectMetadata(
    from value: Any,
    relativeTo postURL: URL,
    title: inout String?,
    thumbnailURL: inout URL?,
    records: inout [RawRecord],
    recordIndex: inout Int
) {
    if let dictionary = value as? [String: Any] {
        let keys = Dictionary(uniqueKeysWithValues: dictionary.keys.map { ($0.lowercased(), $0) })
        if let videoURLsKey = keys["video_urls"], let videoURLs = dictionary[videoURLsKey] {
            if title == nil { title = stringValue(dictionary, keys: ["title", "post_title", "video_title"]) }
            if thumbnailURL == nil {
                let rawThumbnail = stringValue(dictionary, keys: ["thumbnail_url", "thumbnail", "thumbnailurl", "image"])
                    ?? firstString(in: dictionary, keys: ["image_details"])
                if let rawThumbnail {
                    thumbnailURL = URL(string: rawThumbnail, relativeTo: postURL)?.absoluteURL
                }
            }
            collectRecords(from: videoURLs, records: &records, recordIndex: &recordIndex)
        }
        dictionary.values.forEach {
            collectMetadata(from: $0, relativeTo: postURL, title: &title, thumbnailURL: &thumbnailURL, records: &records, recordIndex: &recordIndex)
        }
    } else if let array = value as? [Any] {
        array.forEach {
            collectMetadata(from: $0, relativeTo: postURL, title: &title, thumbnailURL: &thumbnailURL, records: &records, recordIndex: &recordIndex)
        }
    }
}

private func collectRecords(from value: Any, records: inout [RawRecord], recordIndex: inout Int) {
    if let encoded = value as? String,
       let data = encoded.data(using: .utf8),
       let decoded = try? JSONSerialization.jsonObject(with: data) {
        collectRecords(from: decoded, records: &records, recordIndex: &recordIndex)
    } else if let dictionary = value as? [String: Any] {
        let keys = Dictionary(uniqueKeysWithValues: dictionary.keys.map { ($0.lowercased(), $0) })
        if let linkKey = keys["link"], let linkItems = dictionary[linkKey] as? [Any] {
            collectLinkTuples(linkItems, records: &records, recordIndex: &recordIndex)
            if let iframeKey = keys["iframe"], let iframeItems = dictionary[iframeKey] as? [Any] {
                iframeItems.forEach { collectRecords(from: $0, records: &records, recordIndex: &recordIndex) }
            }
        } else if let embedURL = stringValue(dictionary, keys: ["embed_url", "embedurl"]) {
            let provider = stringValue(dictionary, keys: ["hosting_provider", "hostingprovider"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? "UNKNOWN"
            let iframeURL = publicURL(from: embedURL)
            records.append(
                RawRecord(
                    index: recordIndex,
                    providerName: provider,
                    fileCode: normalizedFileCode(stringValue(dictionary, keys: ["file_code", "filecode"])) ?? fileCode(from: iframeURL),
                    linkURL: nil,
                    iframeURL: iframeURL
                )
            )
            recordIndex += 1
        } else if keys["link"] != nil || keys["iframe"] != nil {
            let provider = stringValue(dictionary, keys: ["hosting_provider", "hostingprovider"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? "UNKNOWN"
            let fileCode = stringValue(dictionary, keys: ["file_code", "filecode"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let link = stringValue(dictionary, keys: ["link"])
            let iframe = stringValue(dictionary, keys: ["iframe"])
            records.append(
                RawRecord(
                    index: recordIndex,
                    providerName: provider,
                    fileCode: fileCode?.isEmpty == false ? fileCode : nil,
                    linkURL: publicURL(from: link),
                    iframeURL: publicURL(from: iframe)
                )
            )
            recordIndex += 1
        } else {
            dictionary.values.forEach { collectRecords(from: $0, records: &records, recordIndex: &recordIndex) }
        }
    } else if let array = value as? [Any] {
        array.forEach { collectRecords(from: $0, records: &records, recordIndex: &recordIndex) }
    }
}

private func collectLinkTuples(_ values: [Any], records: inout [RawRecord], recordIndex: inout Int) {
    for value in values {
        guard let tuple = value as? [Any], tuple.count >= 2,
              let provider = tuple[0] as? String,
              let link = tuple[1] as? String else {
            collectRecords(from: value, records: &records, recordIndex: &recordIndex)
            continue
        }
        let linkURL = publicURL(from: link)
        records.append(
            RawRecord(
                index: recordIndex,
                providerName: provider.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                fileCode: fileCode(from: linkURL),
                linkURL: linkURL,
                iframeURL: nil
            )
        )
        recordIndex += 1
    }
}

private func pairedCandidates(from records: [RawRecord]) -> [AllPornStreamCandidate] {
    var order: [String] = []
    var grouped: [String: RawRecord] = [:]
    for record in records {
        let fallback = record.iframeURL?.absoluteString ?? record.linkURL?.absoluteString ?? "record-\(record.index)"
        let key = "\(record.providerName)|\(record.fileCode?.lowercased() ?? fallback)"
        if let existing = grouped[key] {
            grouped[key] = RawRecord(
                index: existing.index,
                providerName: existing.providerName,
                fileCode: existing.fileCode ?? record.fileCode,
                linkURL: existing.linkURL ?? record.linkURL,
                iframeURL: existing.iframeURL ?? record.iframeURL
            )
        } else {
            grouped[key] = record
            order.append(key)
        }
    }
    return order.compactMap { key in
        guard let record = grouped[key] else { return nil }
        return AllPornStreamCandidate(
            providerName: record.providerName,
            fileCode: record.fileCode,
            sourceURL: record.iframeURL ?? record.linkURL,
            trustedProvider: trustedProvider(for: record.providerName)
                ?? myDaddyProvider(for: record.iframeURL ?? record.linkURL)
        )
    }
}

private func trustedProvider(for name: String) -> ProviderKind? {
    let normalized = name.uppercased().filter { $0.isLetter || $0.isNumber }
    return switch normalized {
    case "DOODSTREAM", "DOOD", "PLAYMOGO", "VIDE0": .doodStream
    case "MIXDROP", "MIXDROPNET", "MIIXDROP", "MIIXDROPNET", "MIIIXDROP", "MIIIXDROPNET", "MIIIIXDROP", "MIIIIXDROPNET", "MIIIIIXDROP", "MIIIIIXDROPNET": .mixDrop
    case "STREAMTAPE": .streamTape
    default: nil
    }
}

private func myDaddyProvider(for url: URL?) -> ProviderKind? {
    guard let host = url?.host?.lowercased(),
          host == "mydaddy.cc" || host.hasSuffix(".mydaddy.cc") else {
        return nil
    }
    return .myDaddy
}

private func normalizedFileCode(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
}

private func fileCode(from url: URL?) -> String? {
    guard let lastPathComponent = url?.pathComponents.last, !lastPathComponent.isEmpty, lastPathComponent != "/" else { return nil }
    return lastPathComponent
}

private func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
    let lookup = Dictionary(uniqueKeysWithValues: dictionary.keys.map { ($0.lowercased(), $0) })
    for key in keys {
        guard let value = lookup[key.lowercased()].flatMap({ dictionary[$0] }) else { continue }
        if let strings = value as? [String], let first = strings.first, !first.isEmpty {
            return first
        }
        if let values = value as? [Any], let first = values.compactMap({ $0 as? String }).first, !first.isEmpty {
            return first
        }
    }
    return nil
}

private func publicURL(from value: String?) -> URL? {
    guard let value, let url = URL(string: value.replacingOccurrences(of: "\\/", with: "/"))?.absoluteURL,
          URLSafetyPolicy.isAllowed(url) else { return nil }
    return url
}

private func videoURLValues(in source: String) -> [Any] {
    var values: [Any] = []
    guard let regex = try? NSRegularExpression(pattern: #"(?:["']?video_urls["']?)\s*[:=]\s*"#, options: [.caseInsensitive]) else {
        return values
    }
    let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
    for match in matches.reversed() {
        guard let start = Range(match.range, in: source)?.upperBound,
              let segment = balancedSegment(in: source, from: start, open: "[", close: "]", includeOpeningCharacter: false),
              let data = segment.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            continue
        }
        values.insert(value, at: 0)
    }
    return values
}

private func stringValue(_ dictionary: [String: Any], keys: [String]) -> String? {
    let lookup = Dictionary(uniqueKeysWithValues: dictionary.keys.map { ($0.lowercased(), $0) })
    for key in keys {
        if let value = lookup[key.lowercased()].flatMap({ dictionary[$0] as? String }), !value.isEmpty {
            return value
        }
    }
    return nil
}

private func firstStringValue(for keys: [String], in source: String) -> String? {
    for key in keys {
        let pattern = "\\\"\(NSRegularExpression.escapedPattern(for: key))\\\"\\s*:\\s*\\\"([^\\\"]+)\\\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { continue }
        return String(source[range])
            .replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\/"#, with: "/")
    }
    return nil
}

private func traceLine(for attempt: ProviderAttempt) -> String {
    let source = attempt.sourceURL?.absoluteString ?? "missing source URL"
    switch attempt.outcome {
    case .resolved:
        return "\(attempt.providerName) resolved from \(source) via \(attempt.resolutionMethod ?? "static resolver")."
    case .verificationRequired:
        return "\(attempt.providerName) requires verification at \(source): \(attempt.reason ?? "Cloudflare challenge")."
    case .timedOut:
        return "\(attempt.providerName) timed out at \(source): \(attempt.reason ?? "Timed out")."
    case .failed:
        return "\(attempt.providerName) failed at \(source): \(attempt.reason ?? "Static resolution failed.")"
    }
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
