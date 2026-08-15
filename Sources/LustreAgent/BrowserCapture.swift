import AppKit
import Darwin
import Foundation
import LustreCore

public enum BrowserCaptureConstants {
    public static let extensionID = "bflialnfhbmofpgeigfgpiclhgllfhni"
    public static let extensionOrigin = "chrome-extension://\(extensionID)/"
    public static let firefoxExtensionID = "lustre-allpornstream@pmvdl.local"
    public static let nativeHostName = "com.pmvdl.lustre_browser_bridge"
    public static let maximumMessageBytes = 256 * 1024
    public static let captureTimeout: TimeInterval = 5 * 60
    public static let socketURL = AgentPaths.applicationSupport.appending(path: "browser-capture.sock")
    public static let extensionURL = AgentPaths.applicationSupport.appending(path: "ChromeExtension", directoryHint: .isDirectory)
    public static let firefoxExtensionURL = AgentPaths.applicationSupport.appending(path: "FirefoxExtension", directoryHint: .isDirectory)
    public static let browserPreferenceURL = AgentPaths.applicationSupport.appending(path: "browser-capture-browser")
}

public enum BrowserCaptureError: Error, LocalizedError, Sendable {
    case browserExtensionRequired
    case timeout
    case cancelled
    case invalidCapture
    case browserClosed

    public var errorDescription: String? {
        switch self {
        case .browserExtensionRequired: "Install and enable the selected Lustre browser extension on the paired Mac."
        case .timeout: "AllPornStream browser verification timed out."
        case .cancelled: "AllPornStream capture was cancelled."
        case .invalidCapture: "The browser returned invalid AllPornStream Feed metadata."
        case .browserClosed: "The AllPornStream capture tab was closed before verification completed."
        }
    }
}

public struct BrowserIntegrationStatus: Codable, Sendable {
    public let chromeIsDefault: Bool
    public let extensionIsStaged: Bool
    public let nativeHostIsInstalled: Bool
    public let extensionID: String
    public let extensionDirectory: String
}

public struct FirefoxBrowserIntegrationStatus: Codable, Sendable {
    public let firefoxIsInstalled: Bool
    public let extensionIsStaged: Bool
    public let nativeHostIsInstalled: Bool
    public let extensionID: String
    public let extensionDirectory: String
}

public enum BrowserIntegration {
    public static func status() -> BrowserIntegrationStatus {
        let workspace = NSWorkspace.shared
        let chromeIsDefault = workspace.urlForApplication(toOpen: URL(string: "https://allpornstream.com")!)?.pathExtension == "app"
            && workspace.urlForApplication(toOpen: URL(string: "https://allpornstream.com")!)?.lastPathComponent == "Google Chrome.app"
        return BrowserIntegrationStatus(
            chromeIsDefault: chromeIsDefault,
            extensionIsStaged: FileManager.default.fileExists(atPath: BrowserCaptureConstants.extensionURL.appending(path: "manifest.json").path),
            nativeHostIsInstalled: chromiumNativeHostManifestURLs.contains { FileManager.default.fileExists(atPath: $0.path) },
            extensionID: BrowserCaptureConstants.extensionID,
            extensionDirectory: BrowserCaptureConstants.extensionURL.path
        )
    }

    public static func installChrome(runningExecutable: URL? = Bundle.main.executableURL) throws -> BrowserIntegrationStatus {
        try AgentPaths.prepare()
        guard let resource = Bundle.module.url(forResource: "ChromeExtension", withExtension: nil) else {
            throw BrowserCaptureError.browserExtensionRequired
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: BrowserCaptureConstants.extensionURL.path) {
            try fileManager.removeItem(at: BrowserCaptureConstants.extensionURL)
        }
        try fileManager.copyItem(at: resource, to: BrowserCaptureConstants.extensionURL)

        guard let executable = runningExecutable else { throw BrowserCaptureError.browserExtensionRequired }
        let bridge = executable.deletingLastPathComponent().appending(path: "lustre-browser-bridge")
        guard fileManager.isExecutableFile(atPath: bridge.path) else { throw BrowserCaptureError.browserExtensionRequired }
        let manifest: [String: Any] = [
            "name": BrowserCaptureConstants.nativeHostName,
            "description": "Lustre AllPornStream browser capture bridge",
            "path": bridge.path,
            "type": "stdio",
            "allowed_origins": [BrowserCaptureConstants.extensionOrigin]
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        for manifestURL in chromiumNativeHostManifestURLs {
            try fileManager.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manifestData.write(to: manifestURL, options: .atomic)
        }
        try Data("chrome".utf8).write(to: BrowserCaptureConstants.browserPreferenceURL, options: .atomic)
        return status()
    }

    public static func firefoxStatus() -> FirefoxBrowserIntegrationStatus {
        FirefoxBrowserIntegrationStatus(
            firefoxIsInstalled: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.mozilla.firefox") != nil,
            extensionIsStaged: FileManager.default.fileExists(atPath: BrowserCaptureConstants.firefoxExtensionURL.appending(path: "manifest.json").path),
            nativeHostIsInstalled: FileManager.default.fileExists(atPath: firefoxNativeHostManifestURL.path),
            extensionID: BrowserCaptureConstants.firefoxExtensionID,
            extensionDirectory: BrowserCaptureConstants.firefoxExtensionURL.path
        )
    }

    public static func installFirefox(runningExecutable: URL? = Bundle.main.executableURL) throws -> FirefoxBrowserIntegrationStatus {
        try AgentPaths.prepare()
        guard let extensionResource = Bundle.module.url(forResource: "ChromeExtension", withExtension: nil),
              let manifestResource = Bundle.module.url(forResource: "FirefoxManifest", withExtension: "json")
        else { throw BrowserCaptureError.browserExtensionRequired }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: BrowserCaptureConstants.firefoxExtensionURL.path) {
            try fileManager.removeItem(at: BrowserCaptureConstants.firefoxExtensionURL)
        }
        try fileManager.copyItem(at: extensionResource, to: BrowserCaptureConstants.firefoxExtensionURL)
        let stagedManifest = BrowserCaptureConstants.firefoxExtensionURL.appending(path: "manifest.json")
        try fileManager.removeItem(at: stagedManifest)
        try fileManager.copyItem(at: manifestResource, to: stagedManifest)

        guard let executable = runningExecutable else { throw BrowserCaptureError.browserExtensionRequired }
        let bridge = executable.deletingLastPathComponent().appending(path: "lustre-browser-bridge")
        guard fileManager.isExecutableFile(atPath: bridge.path) else { throw BrowserCaptureError.browserExtensionRequired }
        try fileManager.createDirectory(at: firefoxNativeHostManifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": BrowserCaptureConstants.nativeHostName,
            "description": "Lustre AllPornStream browser capture bridge",
            "path": bridge.path,
            "type": "stdio",
            "allowed_extensions": [BrowserCaptureConstants.firefoxExtensionID]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: firefoxNativeHostManifestURL, options: .atomic)
        try Data("firefox".utf8).write(to: BrowserCaptureConstants.browserPreferenceURL, options: .atomic)
        return firefoxStatus()
    }

    public static func preferredApplication() -> URL? {
        let preference = (try? String(contentsOf: BrowserCaptureConstants.browserPreferenceURL, encoding: .utf8)) ?? "chrome"
        if preference == "firefox" {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.mozilla.firefox")
        }
        let workspace = NSWorkspace.shared
        if let selected = workspace.urlForApplication(toOpen: URL(string: "https://allpornstream.com")!),
           ["com.google.Chrome", "com.brave.Browser", "com.kagi.kagimacOS"].contains(Bundle(url: selected)?.bundleIdentifier) {
            return selected
        }
        return ["com.google.Chrome", "com.brave.Browser", "com.kagi.kagimacOS"]
            .lazy.compactMap(workspace.urlForApplication(withBundleIdentifier:)).first
    }

    public static func selectedIntegrationIsReady() -> Bool {
        let preference = (try? String(contentsOf: BrowserCaptureConstants.browserPreferenceURL, encoding: .utf8)) ?? "chrome"
        if preference == "firefox" {
            let status = firefoxStatus()
            return status.firefoxIsInstalled && status.extensionIsStaged && status.nativeHostIsInstalled
        }
        let chrome = status()
        return chrome.extensionIsStaged && chrome.nativeHostIsInstalled
    }

    public static func openChromeExtensions() {
        guard let chrome = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://allpornstream.com")!),
              let identifier = Bundle(url: chrome)?.bundleIdentifier,
              ["com.google.Chrome", "com.brave.Browser", "com.kagi.kagimacOS"].contains(identifier) else { return }
        let scheme = identifier == "com.brave.Browser" ? "brave" : identifier == "com.kagi.kagimacOS" ? "orion" : "chrome"
        NSWorkspace.shared.open([URL(string: "\(scheme)://extensions")!], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }

    private static var chromiumNativeHostManifestURLs: [URL] {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [
            applicationSupport.appending(path: "Google/Chrome/NativeMessagingHosts/\(BrowserCaptureConstants.nativeHostName).json"),
            applicationSupport.appending(path: "BraveSoftware/Brave-Browser/NativeMessagingHosts/\(BrowserCaptureConstants.nativeHostName).json")
        ]
    }

    private static var firefoxNativeHostManifestURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mozilla/NativeMessagingHosts/\(BrowserCaptureConstants.nativeHostName).json")
    }
}

struct BrowserFeedCapture: Codable, Sendable {
    let type: String
    let version: Int
    let requestID: UUID
    let siteID: String
    let pageURL: URL
    let capturedAt: Date
    let cards: [BrowserFeedCard]
    let hasMore: Bool
}

struct BrowserFeedCard: Codable, Sendable {
    let title: String
    let sourcePageURL: URL
    let thumbnailURL: URL?
    let previewURLs: [URL]
    let uploadedAt: Date
    let viewCount: Int
    let studio: String?
}

struct BrowserPostCapture: Codable, Sendable {
    let type: String
    let version: Int
    let requestID: UUID
    let siteID: String
    let pageURL: URL
    let capturedAt: Date
    let metadataSources: [String]
}

struct BrowserCaptureResponse: Codable, Sendable {
    let type: String
    let requestID: UUID?
    let code: String?
}

private struct BrowserPornHubAuthCapture: Codable, Sendable {
    let type: String
    let version: Int
    let requestID: UUID
    let pageURL: URL
    let capturedAt: Date
    let cookies: [PornHubCookieRecord]
}

public actor AllPornStreamCaptureCoordinator {
    private struct Pending {
        let expectedURL: URL
        let page: Int
        let continuation: CheckedContinuation<FeedPage, Error>
    }

    private struct PendingPost {
        let expectedURL: URL
        let continuation: CheckedContinuation<String, Error>
    }

    private struct PendingPornHubAuth {
        let continuation: CheckedContinuation<[PornHubCookieRecord], Error>
    }

    private var server: BrowserCaptureSocketServer?
    private var pending: [UUID: Pending] = [:]
    private var pendingPosts: [UUID: PendingPost] = [:]
    private var pendingPornHubAuth: [UUID: PendingPornHubAuth] = [:]
    private var inFlight: [String: Task<FeedPage, Error>] = [:]
    private var inFlightPosts: [String: Task<String, Error>] = [:]
    private let openPage: @Sendable (URL) async throws -> Void
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = BrowserCaptureConstants.captureTimeout, openPage: (@Sendable (URL) async throws -> Void)? = nil) {
        self.timeout = timeout
        self.openPage = openPage ?? { url in
            try await MainActor.run {
                guard BrowserIntegration.selectedIntegrationIsReady(),
                      let browser = BrowserIntegration.preferredApplication()
                else { throw BrowserCaptureError.browserExtensionRequired }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: configuration)
            }
        }
    }

    public func start() throws {
        guard server == nil else { return }
        let created = try BrowserCaptureSocketServer(path: BrowserCaptureConstants.socketURL.path) { [weak self] data in
            guard let self else { return Data() }
            return await self.receive(data)
        }
        server = created
        created.start()
    }

    public func stop() {
        server?.stop()
        server = nil
        let continuations = pending.values.map(\.continuation)
        let postContinuations = pendingPosts.values.map(\.continuation)
        let pornHubAuthContinuations = pendingPornHubAuth.values.map(\.continuation)
        pending.removeAll()
        pendingPosts.removeAll()
        pendingPornHubAuth.removeAll()
        inFlight.removeAll()
        inFlightPosts.removeAll()
        continuations.forEach { $0.resume(throwing: BrowserCaptureError.cancelled) }
        postContinuations.forEach { $0.resume(throwing: BrowserCaptureError.cancelled) }
        pornHubAuthContinuations.forEach { $0.resume(throwing: BrowserCaptureError.cancelled) }
    }

    public func capture(url: URL, page: Int) async throws -> FeedPage {
        let key = "\(url.absoluteString)|\(page)"
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await performCapture(url: url, page: page) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    public func capturePost(url: URL) async throws -> String {
        let key = url.absoluteString
        if let task = inFlightPosts[key] { return try await task.value }
        let task = Task { try await performPostCapture(url: url) }
        inFlightPosts[key] = task
        defer { inFlightPosts[key] = nil }
        return try await task.value
    }

    public func authenticatePornHub() async throws -> [PornHubCookieRecord] {
        let requestID = UUID()
        var components = URLComponents(string: "https://www.pornhub.com/login")!
        components.fragment = "lustre-pornhub-auth=\(requestID.uuidString.lowercased())"
        guard let url = components.url else { throw BrowserCaptureError.invalidCapture }
        let captureTimeout = timeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingPornHubAuth[requestID] = PendingPornHubAuth(continuation: continuation)
                Task {
                    do {
                        try await openPage(url)
                    } catch {
                        failPornHubAuth(requestID: requestID, error: error)
                    }
                }
                Task {
                    try? await Task.sleep(for: .seconds(captureTimeout))
                    failPornHubAuth(requestID: requestID, error: PornHubAuthError.timeout)
                }
            }
        } onCancel: {
            Task { await self.cancelPornHubAuth(requestID: requestID) }
        }
    }

    private func performCapture(url: URL, page: Int) async throws -> FeedPage {
        guard trustedPage(url), page > 0 else { throw BrowserCaptureError.invalidCapture }
        let requestID = UUID()
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = "lustre-feed-capture=\(requestID.uuidString.lowercased())"
        guard let markedURL = components?.url else { throw BrowserCaptureError.invalidCapture }
        let captureTimeout = timeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(requestID: requestID, url: url, page: page, continuation: continuation)
                Task {
                    do {
                        try await openPage(markedURL)
                    } catch {
                        fail(requestID: requestID, error: error)
                    }
                }
                Task {
                    try? await Task.sleep(for: .seconds(captureTimeout))
                    fail(requestID: requestID, error: BrowserCaptureError.timeout)
                }
            }
        } onCancel: {
            Task { await self.cancel(requestID: requestID) }
        }
    }

    private func performPostCapture(url: URL) async throws -> String {
        guard trustedPage(url), url.path.hasPrefix("/post/") else { throw BrowserCaptureError.invalidCapture }
        let requestID = UUID()
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = "lustre-post-capture=\(requestID.uuidString.lowercased())"
        guard let markedURL = components?.url else { throw BrowserCaptureError.invalidCapture }
        let captureTimeout = timeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingPosts[requestID] = PendingPost(expectedURL: url, continuation: continuation)
                Task {
                    do {
                        try await openPage(markedURL)
                    } catch {
                        failPost(requestID: requestID, error: error)
                    }
                }
                Task {
                    try? await Task.sleep(for: .seconds(captureTimeout))
                    failPost(requestID: requestID, error: BrowserCaptureError.timeout)
                }
            }
        } onCancel: {
            Task { await self.cancelPost(requestID: requestID) }
        }
    }

    private func register(requestID: UUID, url: URL, page: Int, continuation: CheckedContinuation<FeedPage, Error>) {
        pending[requestID] = Pending(expectedURL: url, page: page, continuation: continuation)
    }

    private func cancel(requestID: UUID) {
        pending.removeValue(forKey: requestID)?.continuation.resume(throwing: BrowserCaptureError.cancelled)
    }

    private func cancelPost(requestID: UUID) {
        pendingPosts.removeValue(forKey: requestID)?.continuation.resume(throwing: BrowserCaptureError.cancelled)
    }

    private func fail(requestID: UUID, error: Error) {
        pending.removeValue(forKey: requestID)?.continuation.resume(throwing: error)
    }

    private func failPost(requestID: UUID, error: Error) {
        pendingPosts.removeValue(forKey: requestID)?.continuation.resume(throwing: error)
    }

    private func cancelPornHubAuth(requestID: UUID) {
        pendingPornHubAuth.removeValue(forKey: requestID)?.continuation.resume(throwing: PornHubAuthError.cancelled)
    }

    private func failPornHubAuth(requestID: UUID, error: Error) {
        pendingPornHubAuth.removeValue(forKey: requestID)?.continuation.resume(throwing: error)
    }

    private func receive(_ data: Data) -> Data {
        if let closed = try? JSONDecoder().decode(BrowserCaptureClosed.self, from: data),
           closed.type == "pornhub_auth_closed_v1", closed.version == 1,
           let request = pendingPornHubAuth.removeValue(forKey: closed.requestID) {
            request.continuation.resume(throwing: PornHubAuthError.cancelled)
            return encode(BrowserCaptureResponse(type: "capture_rejected", requestID: closed.requestID, code: "browser_closed"))
        }
        if let closed = try? JSONDecoder().decode(BrowserCaptureClosed.self, from: data),
           closed.type == "capture_closed_v1", closed.version == 1 {
            if let request = pending.removeValue(forKey: closed.requestID) {
                request.continuation.resume(throwing: BrowserCaptureError.browserClosed)
                return encode(BrowserCaptureResponse(type: "capture_rejected", requestID: closed.requestID, code: "browser_closed"))
            }
            if let request = pendingPosts.removeValue(forKey: closed.requestID) {
                request.continuation.resume(throwing: BrowserCaptureError.browserClosed)
                return encode(BrowserCaptureResponse(type: "capture_rejected", requestID: closed.requestID, code: "browser_closed"))
            }
        }
        let decoder = JSONDecoder()
        let fractionalDateStrategy = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let internetDateStrategy = Date.ISO8601FormatStyle()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let dateComponents = value.split(separator: "-").compactMap { Int($0) }
            let day = dateComponents.count == 3
                ? Calendar(identifier: .gregorian).date(from: DateComponents(
                    timeZone: TimeZone(secondsFromGMT: 0),
                    year: dateComponents[0],
                    month: dateComponents[1],
                    day: dateComponents[2]
                ))
                : nil
            guard let date = (try? fractionalDateStrategy.parse(value))
                ?? (try? internetDateStrategy.parse(value))
                ?? day
            else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date.")
            }
            return date
        }
        guard data.count <= BrowserCaptureConstants.maximumMessageBytes else {
            fputs("Lustre browser capture: rejected oversized message.\n", stderr)
            return encode(BrowserCaptureResponse(type: "capture_rejected", requestID: nil, code: "invalid_capture"))
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["type"] as? String == "post_capture_v1" {
            return receivePost(data, decoder: decoder)
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["type"] as? String == "pornhub_auth_v1" {
            return receivePornHubAuth(data, decoder: decoder)
        }
        let capture: BrowserFeedCapture
        do {
            capture = try decoder.decode(BrowserFeedCapture.self, from: data)
        } catch {
            fputs("Lustre browser capture: rejected undecodable message: \(error).\n", stderr)
            return encode(BrowserCaptureResponse(type: "capture_rejected", requestID: nil, code: "invalid_capture"))
        }
        guard let request = pending[capture.requestID] else {
            fputs("Lustre browser capture: rejected unknown request.\n", stderr)
            return encode(BrowserCaptureResponse(type: "capture_rejected", requestID: capture.requestID, code: "invalid_capture"))
        }
        guard let page = validate(capture, pending: request) else {
            fputs("Lustre browser capture: rejected invalid metadata for \(capture.pageURL.absoluteString) with \(capture.cards.count) cards.\n", stderr)
            return encode(BrowserCaptureResponse(type: "capture_rejected", requestID: capture.requestID, code: "invalid_capture"))
        }
        pending.removeValue(forKey: capture.requestID)
        request.continuation.resume(returning: page)
        return encode(BrowserCaptureResponse(type: "capture_accepted", requestID: capture.requestID, code: nil))
    }

    private func receivePornHubAuth(_ data: Data, decoder: JSONDecoder) -> Data {
        guard let capture = try? decoder.decode(BrowserPornHubAuthCapture.self, from: data),
              capture.type == "pornhub_auth_v1", capture.version == 1,
              let pending = pendingPornHubAuth[capture.requestID],
              capture.pageURL.scheme?.lowercased() == "https",
              capture.pageURL.host.map(PornHubCookieSanitizer.isAllowedDomain) == true,
              abs(capture.capturedAt.timeIntervalSinceNow) <= BrowserCaptureConstants.captureTimeout,
              PornHubAuthenticationValidation.isAuthenticated(PornHubAuthenticationMarkers(
                hasSessionCookie: PornHubHelperCookieCandidatePolicy.hasSessionProofCandidate(capture.cookies),
                pageReportsAuthenticatedUser: true
              )),
              let cookies = try? PornHubHelperCookieCandidatePolicy.sanitizeTrustedCookies(capture.cookies),
              PornHubHelperCookieCandidatePolicy.hasSessionProofCandidate(cookies)
        else {
            return encode(BrowserCaptureResponse(type: "capture_rejected", requestID: nil, code: "invalid_capture"))
        }
        pendingPornHubAuth.removeValue(forKey: capture.requestID)
        pending.continuation.resume(returning: cookies)
        return encode(BrowserCaptureResponse(type: "capture_accepted", requestID: capture.requestID, code: nil))
    }

    private func receivePost(_ data: Data, decoder: JSONDecoder) -> Data {
        guard let capture = try? decoder.decode(BrowserPostCapture.self, from: data),
              let request = pendingPosts[capture.requestID],
              capture.type == "post_capture_v1", capture.version == 1,
              capture.siteID == FeedSiteID.allPornStream.rawValue,
              samePage(capture.pageURL, request.expectedURL),
              trustedPage(capture.pageURL), capture.pageURL.path.hasPrefix("/post/"),
              abs(capture.capturedAt.timeIntervalSinceNow) <= BrowserCaptureConstants.captureTimeout,
              !capture.metadataSources.isEmpty, capture.metadataSources.count <= 16
        else {
            return encode(BrowserCaptureResponse(type: "capture_rejected", requestID: nil, code: "invalid_capture"))
        }
        var totalBytes = 0
        for source in capture.metadataSources {
            let bytes = source.utf8.count
            guard bytes > 0, bytes <= 32 * 1024, totalBytes + bytes <= 128 * 1024,
                  source.localizedCaseInsensitiveContains("video_urls")
                    || source.localizedCaseInsensitiveContains("hosting_provider")
            else {
                return encode(BrowserCaptureResponse(type: "capture_rejected", requestID: capture.requestID, code: "invalid_capture"))
            }
            totalBytes += bytes
        }
        let html = capture.metadataSources.map { "<script>\($0)</script>" }.joined(separator: "\n")
        pendingPosts.removeValue(forKey: capture.requestID)
        request.continuation.resume(returning: html)
        return encode(BrowserCaptureResponse(type: "capture_accepted", requestID: capture.requestID, code: nil))
    }

    private func validate(_ capture: BrowserFeedCapture, pending request: Pending) -> FeedPage? {
        func rejected(_ reason: String) -> FeedPage? {
            fputs("Lustre browser capture: metadata validation failed: \(reason).\n", stderr)
            return nil
        }
        guard capture.type == "feed_capture_v1", capture.version == 1, capture.siteID == FeedSiteID.allPornStream.rawValue,
              samePage(capture.pageURL, request.expectedURL), trustedPage(capture.pageURL),
              abs(capture.capturedAt.timeIntervalSinceNow) <= BrowserCaptureConstants.captureTimeout,
              !capture.cards.isEmpty, capture.cards.count <= 50
        else { return rejected("envelope") }
        var seen = Set<String>()
        var items: [FeedItem] = []
        for (index, card) in capture.cards.enumerated() {
            guard !card.title.isEmpty, card.title.count <= 512,
                  card.title.rangeOfCharacter(from: .controlCharacters) == nil
            else { return rejected("card \(index) title") }
            guard trustedPage(card.sourcePageURL), card.sourcePageURL.path.hasPrefix("/post/")
            else { return rejected("card \(index) source") }
            guard seen.insert(card.sourcePageURL.absoluteString).inserted
            else { return rejected("card \(index) duplicate") }
            guard
                  card.previewURLs.count <= 4,
                  card.viewCount >= 0, card.viewCount <= 1_000_000_000_000,
                  card.studio?.count ?? 0 <= 256
            else { return rejected("card \(index) bounds") }
            guard [card.thumbnailURL].compactMap({ $0 }).allSatisfy(trustedAsset),
                  card.previewURLs.allSatisfy(trustedAsset)
            else { return rejected("card \(index) asset") }
            guard let id = card.sourcePageURL.path.split(separator: "/").last.map(String.init), !id.isEmpty
            else { return rejected("card \(index) identifier") }
            let studio = card.studio ?? card.title.range(of: #"^\[([^\]]+)\]"#, options: .regularExpression).map {
                String(card.title[$0].dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            items.append(FeedItem(id: id, siteID: .allPornStream, title: card.title, sourcePageURL: card.sourcePageURL, thumbnailURL: card.thumbnailURL, previewURLs: card.previewURLs, uploadedAt: card.uploadedAt, viewCount: card.viewCount, studio: studio?.isEmpty == true ? nil : studio, queueCapability: .supported))
        }
        return FeedPage(items: items, page: request.page, hasMore: capture.hasMore)
    }

    private func trustedPage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && ["allpornstream.com", "www.allpornstream.com"].contains(url.host?.lowercased() ?? "")
    }

    private func samePage(_ left: URL, _ right: URL) -> Bool {
        guard var leftComponents = URLComponents(url: left, resolvingAgainstBaseURL: false),
              var rightComponents = URLComponents(url: right, resolvingAgainstBaseURL: false)
        else { return false }
        leftComponents.fragment = nil
        rightComponents.fragment = nil
        if leftComponents.path.isEmpty { leftComponents.path = "/" }
        if rightComponents.path.isEmpty { rightComponents.path = "/" }
        return leftComponents == rightComponents
    }

    private func trustedAsset(_ url: URL) -> Bool {
        trustedPage(url) && url.path == "/api/images"
    }

    private func encode(_ response: BrowserCaptureResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data(#"{"type":"capture_rejected","code":"encoding_failed"}"#.utf8)
    }

    func receiveForTesting(_ data: Data) -> Data {
        receive(data)
    }
}

private struct BrowserCaptureClosed: Codable {
    let type: String
    let version: Int
    let requestID: UUID
}

final class BrowserCaptureSocketServer: @unchecked Sendable {
    private let path: String
    private let handler: @Sendable (Data) async -> Data
    private let queue = DispatchQueue(label: "com.pmvdl.lustre.browser-capture")
    private var descriptor: Int32 = -1

    init(path: String, handler: @escaping @Sendable (Data) async -> Data) throws {
        self.path = path
        self.handler = handler
        try AgentPaths.prepare()
        unlink(path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrowserCaptureError.browserExtensionRequired }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw BrowserCaptureError.browserExtensionRequired }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                _ = bytes.withUnsafeBufferPointer { source in strcpy(destination, source.baseAddress!) }
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, chmod(path, S_IRUSR | S_IWUSR) == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            descriptor = -1
            throw BrowserCaptureError.browserExtensionRequired
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            while descriptor >= 0 {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { continue }
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
                Task {
                    defer { close(client) }
                    guard let data = BrowserNativeFraming.read(from: client, maximumBytes: BrowserCaptureConstants.maximumMessageBytes) else { return }
                    BrowserNativeFraming.write(await handler(data), to: client)
                }
            }
        }
    }

    func stop() {
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
        unlink(path)
    }

    deinit { stop() }
}

public enum BrowserNativeFraming {
    public static func read(from descriptor: Int32, maximumBytes: Int) -> Data? {
        guard let header = readExactly(4, from: descriptor) else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length > 0, length <= maximumBytes else { return nil }
        return readExactly(Int(length), from: descriptor)
    }

    public static func write(_ data: Data, to descriptor: Int32) {
        guard data.count <= BrowserCaptureConstants.maximumMessageBytes else { return }
        var length = UInt32(data.count).littleEndian
        withUnsafeBytes(of: &length) { _ = writeAll(Data($0), to: descriptor) }
        _ = writeAll(data, to: descriptor)
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) -> Data? {
        var data = Data(count: count)
        let received = data.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < count {
                let result = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
                if result <= 0 { return offset }
                offset += result
            }
            return offset
        }
        return received == count ? data : nil
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let result = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if result <= 0 { return false }
                offset += result
            }
            return true
        }
    }
}
