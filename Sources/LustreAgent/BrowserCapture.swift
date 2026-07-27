import AppKit
import Darwin
import Foundation
import LustreCore

public enum BrowserCaptureConstants {
    public static let extensionID = "bflialnfhbmofpgeigfgpiclhgllfhni"
    public static let extensionOrigin = "chrome-extension://\(extensionID)/"
    public static let nativeHostName = "com.pmvdl.lustre_browser_bridge"
    public static let maximumMessageBytes = 256 * 1024
    public static let captureTimeout: TimeInterval = 5 * 60
    public static let socketURL = AgentPaths.applicationSupport.appending(path: "browser-capture.sock")
    public static let extensionURL = AgentPaths.applicationSupport.appending(path: "ChromeExtension", directoryHint: .isDirectory)
}

public enum BrowserCaptureError: Error, LocalizedError, Sendable {
    case browserExtensionRequired
    case timeout
    case cancelled
    case invalidCapture
    case browserClosed

    public var errorDescription: String? {
        switch self {
        case .browserExtensionRequired: "Install and enable the Lustre Chrome extension on the paired Mac."
        case .timeout: "AllPornStream verification in Chrome timed out."
        case .cancelled: "AllPornStream capture was cancelled."
        case .invalidCapture: "Chrome returned invalid AllPornStream Feed metadata."
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

public enum BrowserIntegration {
    public static func status() -> BrowserIntegrationStatus {
        let workspace = NSWorkspace.shared
        let chromeIsDefault = workspace.urlForApplication(toOpen: URL(string: "https://allpornstream.com")!)?.pathExtension == "app"
            && workspace.urlForApplication(toOpen: URL(string: "https://allpornstream.com")!)?.lastPathComponent == "Google Chrome.app"
        return BrowserIntegrationStatus(
            chromeIsDefault: chromeIsDefault,
            extensionIsStaged: FileManager.default.fileExists(atPath: BrowserCaptureConstants.extensionURL.appending(path: "manifest.json").path),
            nativeHostIsInstalled: FileManager.default.fileExists(atPath: nativeHostManifestURL.path),
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
        try fileManager.createDirectory(at: nativeHostManifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": BrowserCaptureConstants.nativeHostName,
            "description": "Lustre AllPornStream browser capture bridge",
            "path": bridge.path,
            "type": "stdio",
            "allowed_origins": [BrowserCaptureConstants.extensionOrigin]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: nativeHostManifestURL, options: .atomic)
        return status()
    }

    public static func openChromeExtensions() {
        guard let chrome = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://allpornstream.com")!),
              chrome.lastPathComponent == "Google Chrome.app" else { return }
        NSWorkspace.shared.open([URL(string: "chrome://extensions")!], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }

    private static var nativeHostManifestURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Google/Chrome/NativeMessagingHosts/\(BrowserCaptureConstants.nativeHostName).json")
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

struct BrowserCaptureResponse: Codable, Sendable {
    let type: String
    let requestID: UUID?
    let code: String?
}

public actor AllPornStreamCaptureCoordinator {
    private struct Pending {
        let expectedURL: URL
        let page: Int
        let continuation: CheckedContinuation<FeedPage, Error>
    }

    private var server: BrowserCaptureSocketServer?
    private var pending: [UUID: Pending] = [:]
    private var inFlight: [String: Task<FeedPage, Error>] = [:]
    private let openPage: @Sendable (URL) async throws -> Void
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = BrowserCaptureConstants.captureTimeout, openPage: (@Sendable (URL) async throws -> Void)? = nil) {
        self.timeout = timeout
        self.openPage = openPage ?? { url in
            try await MainActor.run {
                let status = BrowserIntegration.status()
                guard status.chromeIsDefault, status.extensionIsStaged, status.nativeHostIsInstalled,
                      let chrome = NSWorkspace.shared.urlForApplication(toOpen: url),
                      chrome.lastPathComponent == "Google Chrome.app"
                else { throw BrowserCaptureError.browserExtensionRequired }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: configuration)
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
        pending.removeAll()
        inFlight.removeAll()
        continuations.forEach { $0.resume(throwing: BrowserCaptureError.cancelled) }
    }

    public func capture(url: URL, page: Int) async throws -> FeedPage {
        let key = "\(url.absoluteString)|\(page)"
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await performCapture(url: url, page: page) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
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

    private func register(requestID: UUID, url: URL, page: Int, continuation: CheckedContinuation<FeedPage, Error>) {
        pending[requestID] = Pending(expectedURL: url, page: page, continuation: continuation)
    }

    private func cancel(requestID: UUID) {
        pending.removeValue(forKey: requestID)?.continuation.resume(throwing: BrowserCaptureError.cancelled)
    }

    private func fail(requestID: UUID, error: Error) {
        pending.removeValue(forKey: requestID)?.continuation.resume(throwing: error)
    }

    private func receive(_ data: Data) -> Data {
        if let closed = try? JSONDecoder().decode(BrowserCaptureClosed.self, from: data),
           closed.type == "capture_closed_v1", closed.version == 1,
           let request = pending.removeValue(forKey: closed.requestID) {
            request.continuation.resume(throwing: BrowserCaptureError.browserClosed)
            return encode(BrowserCaptureResponse(type: "capture_rejected", requestID: closed.requestID, code: "browser_closed"))
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
