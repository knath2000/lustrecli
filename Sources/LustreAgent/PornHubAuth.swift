import Darwin
import Foundation
import Security
import LustreCore

public struct PornHubCookieRecord: Codable, Equatable, Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expiresAt: Date?
    public let secure: Bool
    public let hostOnly: Bool

    public init(name: String, value: String, domain: String, path: String, expiresAt: Date?, secure: Bool, hostOnly: Bool = false) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.secure = secure
        self.hostOnly = hostOnly
    }

    private enum CodingKeys: String, CodingKey { case name, value, domain, path, expiresAt, secure, hostOnly }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        value = try values.decode(String.self, forKey: .value)
        domain = try values.decode(String.self, forKey: .domain)
        path = try values.decode(String.self, forKey: .path)
        expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        secure = try values.decode(Bool.self, forKey: .secure)
        hostOnly = try values.decodeIfPresent(Bool.self, forKey: .hostOnly) ?? false
    }
}

public enum PornHubCookieSanitizer {
    public static let maximumCookies = 48
    public static let maximumAggregateBytes = 24 * 1024

    public static func sanitize(_ cookies: [PornHubCookieRecord], now: Date = .now) throws -> [PornHubCookieRecord] {
        guard cookies.count <= maximumCookies else { throw PornHubAuthError.invalidCookieState }
        var inputBytes = 0
        var result: [PornHubCookieRecord] = []
        var names = Set<String>()

        for cookie in cookies {
            inputBytes = try boundedByteCount(inputBytes, cookie)
            guard let domain = normalizedDomain(cookie.domain),
                  isAllowedDomain(domain), cookie.secure,
                  cookie.expiresAt.map({ $0 > now }) ?? true else {
                continue
            }
            guard (1...128).contains(cookie.name.utf8.count),
                  (1...4096).contains(cookie.value.utf8.count),
                  (1...512).contains(cookie.path.utf8.count),
                  cookie.path.hasPrefix("/"),
                  isSafeCookieName(cookie.name), isSafeCookieField(cookie.value), isSafeCookieField(cookie.path) else {
                throw PornHubAuthError.invalidCookieState
            }
            let identity = "\(cookie.name.lowercased())|\(domain)|\(cookie.path)|\(cookie.hostOnly)"
            guard names.insert(identity).inserted else { throw PornHubAuthError.invalidCookieState }
            result.append(PornHubCookieRecord(
                name: cookie.name, value: cookie.value, domain: domain, path: cookie.path,
                expiresAt: cookie.expiresAt, secure: true, hostOnly: cookie.hostOnly
            ))
        }
        return result
    }

    public static func isAllowedDomain(_ raw: String) -> Bool {
        guard let domain = normalizedDomain(raw) else { return false }
        return domain == "pornhub.com" || domain.hasSuffix(".pornhub.com")
    }

    public static func cookieHeader(_ cookies: [PornHubCookieRecord], for url: URL, now: Date = .now) throws -> String? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), isAllowedDomain(host) else { return nil }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let matching = try sanitize(cookies, now: now)
            .filter { domainMatches($0, host: host) && pathMatches($0.path, requestPath: requestPath) }
            .sorted { left, right in
                if left.path.utf8.count != right.path.utf8.count { return left.path.utf8.count > right.path.utf8.count }
                if left.name != right.name { return left.name < right.name }
                if left.domain != right.domain { return left.domain < right.domain }
                if left.path != right.path { return left.path < right.path }
                return left.hostOnly && !right.hostOnly
            }
        guard !matching.isEmpty else { return nil }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func boundedByteCount(_ total: Int, _ cookie: PornHubCookieRecord) throws -> Int {
        let fields = [cookie.name, cookie.value, cookie.domain, cookie.path]
        var result = total
        for field in fields {
            let (next, overflow) = result.addingReportingOverflow(field.utf8.count)
            guard !overflow, next <= maximumAggregateBytes else { throw PornHubAuthError.invalidCookieState }
            result = next
        }
        return result
    }

    private static func normalizedDomain(_ raw: String) -> String? {
        let lower = raw.lowercased()
        let domain = lower.hasPrefix(".") ? String(lower.dropFirst()) : lower
        guard !domain.isEmpty, !domain.hasPrefix("."), !domain.hasSuffix("."),
              domain.unicodeScalars.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789.-".unicodeScalars.contains($0) }),
              !domain.contains("..") else { return nil }
        return domain
    }

    private static func isSafeCookieName(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(where: { $0.isWhitespace || $0 == "=" || $0 == ";" || $0.isNewline || $0 == "\t" || $0 == "\0" })
    }

    private static func isSafeCookieField(_ value: String) -> Bool {
        !value.contains(where: { $0 == ";" || $0 == "\r" || $0 == "\n" || $0 == "\t" || $0 == "\0" })
    }

    private static func domainMatches(_ cookie: PornHubCookieRecord, host: String) -> Bool {
        cookie.hostOnly ? host == cookie.domain : host == cookie.domain || host.hasSuffix(".\(cookie.domain)")
    }

    private static func pathMatches(_ cookiePath: String, requestPath: String) -> Bool {
        guard requestPath.hasPrefix(cookiePath) else { return false }
        return requestPath == cookiePath || cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).first == "/"
    }
}

public enum PornHubHelperCookieCandidatePolicy {
    public static let maximumRawCookies = 512

    public static func sanitizeTrustedCookies(_ cookies: [PornHubCookieRecord], now: Date = .now) throws -> [PornHubCookieRecord] {
        guard cookies.count <= maximumRawCookies else { throw PornHubAuthError.invalidCookieState }
        return try PornHubCookieSanitizer.sanitize(cookies.filter { PornHubCookieSanitizer.isAllowedDomain($0.domain) }, now: now)
    }

    public static func hasSessionProofCandidate(_ cookies: [PornHubCookieRecord]) -> Bool {
        cookies.contains { $0.name == "il" }
    }

    public static func hasLoginCompletionTrigger(_ cookies: [PornHubCookieRecord]) -> Bool {
        hasSessionProofCandidate(cookies) || cookies.contains { $0.name == "premium_redirect" }
    }

    public static func hasSessionCandidate(_ cookies: [PornHubCookieRecord]) -> Bool {
        hasSessionProofCandidate(cookies)
    }
}

public protocol PornHubCookieStore: Sendable {
    func load() throws -> [PornHubCookieRecord]
    func save(_ cookies: [PornHubCookieRecord]) throws
    func remove() throws
}

protocol PornHubKeychainBackend: Sendable {
    func copyMatching(service: String, account: String) -> (OSStatus, Data?)
    func update(_ data: Data, service: String, account: String) -> OSStatus
    func add(_ data: Data, service: String, account: String) -> OSStatus
    func remove(service: String, account: String) -> OSStatus
}

private final class SecurityPornHubKeychainBackend: PornHubKeychainBackend, @unchecked Sendable {
    func copyMatching(service: String, account: String) -> (OSStatus, Data?) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    func update(_ data: Data, service: String, account: String) -> OSStatus {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ data: Data, service: String, account: String) -> OSStatus {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(query as CFDictionary, nil)
    }

    func remove(service: String, account: String) -> OSStatus {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }
}

public final class KeychainPornHubCookieStore: PornHubCookieStore, @unchecked Sendable {
    public static let service = "com.pmvdl.lustre-agent"
    public static let account = "pornhub.cookies.v1"
    private let backend: any PornHubKeychainBackend

    public init() { backend = SecurityPornHubKeychainBackend() }
    init(backend: any PornHubKeychainBackend) { self.backend = backend }

    public func load() throws -> [PornHubCookieRecord] {
        let (status, data) = backend.copyMatching(service: Self.service, account: Self.account)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw PornHubAuthError.storageUnavailable }
        guard let data else { throw PornHubAuthError.invalidCookieState }
        return try PornHubCookieSanitizer.sanitize(JSONDecoder().decode([PornHubCookieRecord].self, from: data))
    }

    public func save(_ cookies: [PornHubCookieRecord]) throws {
        let data = try JSONEncoder().encode(PornHubCookieSanitizer.sanitize(cookies))
        let status = backend.update(data, service: Self.service, account: Self.account)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound,
              backend.add(data, service: Self.service, account: Self.account) == errSecSuccess else {
            throw PornHubAuthError.storageUnavailable
        }
    }

    public func remove() throws {
        let status = backend.remove(service: Self.service, account: Self.account)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PornHubAuthError.storageUnavailable }
    }
}

public enum PornHubHelperResult: String, Sendable { case signedIn, cancelled, signedOut }
public protocol PornHubAuthHelping: Sendable {
    func login() async throws -> PornHubHelperResult
    func logout() async throws
}

public enum PornHubAuthError: Error, LocalizedError, Equatable, Sendable, CaseIterable {
    case signedOut, signingIn, cancelled, expired, helperUnavailable, helperFailed, timeout, invalidCookieState, storageUnavailable
    public var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in with PornHub before using this feed."
        case .signingIn: "A PornHub sign-in window is already open."
        case .cancelled: "PornHub sign-in was cancelled."
        case .expired: "PornHub sign-in expired. Sign in again."
        case .helperUnavailable: "The bundled PornHub sign-in helper is unavailable."
        case .helperFailed: "The PornHub sign-in helper did not complete."
        case .timeout: "The PornHub sign-in window timed out."
        case .invalidCookieState: "PornHub session data was rejected."
        case .storageUnavailable: "PornHub session storage is unavailable."
        }
    }
}

public enum PornHubHelperNavigationPolicy {
    public static func allows(url: URL?, isMainFrame: Bool, opensNewWindow: Bool, requestsDownload: Bool) -> Bool {
        allows(url: url, isMainFrame: isMainFrame, topLevelURL: nil, opensNewWindow: opensNewWindow, requestsDownload: requestsDownload)
    }

    public static func allowsResponse(url: URL?, canShowMIMEType: Bool) -> Bool {
        allowsResponse(url: url, isMainFrame: true, topLevelURL: nil, canShowMIMEType: canShowMIMEType)
    }

    public static func allows(url: URL?, isMainFrame: Bool, topLevelURL: URL?, opensNewWindow: Bool, requestsDownload: Bool) -> Bool {
        guard !opensNewWindow, !requestsDownload else { return false }
        if isMainFrame { return isTrustedPornHubURL(url) }
        return isTrustedSubframeURL(url, topLevelURL: topLevelURL)
    }

    public static func allowsResponse(url: URL?, isMainFrame: Bool, topLevelURL: URL?, canShowMIMEType: Bool) -> Bool {
        guard canShowMIMEType else { return false }
        if isMainFrame { return isTrustedPornHubURL(url) }
        return isTrustedSubframeURL(url, topLevelURL: topLevelURL)
    }

    private static func isTrustedPornHubURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host else { return false }
        return PornHubCookieSanitizer.isAllowedDomain(host)
    }

    private static func isTrustedSubframeURL(_ url: URL?, topLevelURL: URL?) -> Bool {
        guard isTrustedPornHubURL(topLevelURL), let url, url.scheme?.lowercased() == "https" else { return false }
        return true
    }
}

public struct PornHubAuthenticationMarkers: Equatable, Sendable {
    public let hasSessionCookie: Bool
    public let pageReportsAuthenticatedUser: Bool?

    public init(hasSessionCookie: Bool, pageReportsAuthenticatedUser: Bool?) {
        self.hasSessionCookie = hasSessionCookie
        self.pageReportsAuthenticatedUser = pageReportsAuthenticatedUser
    }
}

public enum PornHubAuthenticationValidation {
    public static func isAuthenticated(_ markers: PornHubAuthenticationMarkers) -> Bool {
        markers.hasSessionCookie && markers.pageReportsAuthenticatedUser == true
    }
}

public enum PornHubHelperValidationAction: Equatable, Sendable { case none, loadSubscriptions, evaluatePage, fail }

public enum PornHubHelperChallengePolicy {
    public static func resetsValidation(authenticationMethod: String) -> Bool {
        authenticationMethod != NSURLAuthenticationMethodServerTrust
    }
}

public struct PornHubHelperValidationCoordinator: Sendable {
    public private(set) var isValidating = false
    private let maximumAttempts: Int
    private var attempts = 0
    private var pendingCookieChange = false

    public init(maximumAttempts: Int = 2) {
        self.maximumAttempts = max(1, maximumAttempts)
    }

    public mutating func cookieChanged(hasSessionCookie: Bool) -> PornHubHelperValidationAction {
        cookieChanged(hasLoginCompletionTrigger: hasSessionCookie)
    }

    public mutating func cookieChanged(hasLoginCompletionTrigger: Bool) -> PornHubHelperValidationAction {
        guard hasLoginCompletionTrigger else {
            reset()
            return .none
        }
        guard !isValidating else {
            pendingCookieChange = true
            return .none
        }
        return beginValidation()
    }

    public mutating func navigationFinished(url: URL?) -> PornHubHelperValidationAction {
        guard isValidating else { return .none }
        return Self.isExactSubscriptionsURL(url) ? .evaluatePage : terminalNavigation()
    }

    public mutating func loginNavigationFinished(url: URL?, hasSessionCookie: Bool) -> PornHubHelperValidationAction {
        loginNavigationFinished(url: url, hasLoginCompletionTrigger: hasSessionCookie)
    }

    public mutating func loginNavigationFinished(url: URL?, hasLoginCompletionTrigger: Bool) -> PornHubHelperValidationAction {
        guard Self.isCompletedLoginNavigation(url) else { return .none }
        return cookieChanged(hasLoginCompletionTrigger: hasLoginCompletionTrigger)
    }

    public mutating func terminalNavigation() -> PornHubHelperValidationAction {
        guard isValidating else { return .none }
        isValidating = false
        pendingCookieChange = false
        return beginValidation()
    }

    public mutating func authenticationChallenge() -> PornHubHelperValidationAction {
        reset()
        return .none
    }

    public mutating func authenticationResult(isAuthenticated: Bool) -> PornHubHelperValidationAction {
        guard isValidating else { return .none }
        isValidating = false
        pendingCookieChange = false
        guard !isAuthenticated else { return .none }
        return beginValidation()
    }

    private mutating func beginValidation() -> PornHubHelperValidationAction {
        guard attempts < maximumAttempts else {
            isValidating = false
            pendingCookieChange = false
            return .fail
        }
        attempts += 1
        isValidating = true
        return .loadSubscriptions
    }

    private mutating func reset() {
        isValidating = false
        attempts = 0
        pendingCookieChange = false
    }

    private static func isExactSubscriptionsURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host,
              host.lowercased() == "www.pornhub.com" else { return false }
        return url.path == "/subscriptions"
    }

    private static func isCompletedLoginNavigation(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host,
              PornHubCookieSanitizer.isAllowedDomain(host) else { return false }
        return url.path != "/login" && !url.path.hasPrefix("/login/")
    }
}

public enum PornHubWebKitCookieCapture {
    public static func record(_ cookie: HTTPCookie) -> PornHubCookieRecord {
        record(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, expiresAt: cookie.expiresDate, secure: cookie.isSecure)
    }

    public static func record(name: String, value: String, domain: String, path: String, expiresAt: Date?, secure: Bool) -> PornHubCookieRecord {
        // Foundation does not expose whether Domain was omitted. Treat a dotless domain as
        // host-only so an ambiguous capture can only narrow, never widen, cookie routing.
        PornHubCookieRecord(name: name, value: value, domain: domain, path: path, expiresAt: expiresAt, secure: secure, hostOnly: !domain.hasPrefix("."))
    }
}

public actor PornHubAuthService {
    private let store: PornHubCookieStore
    private let helper: PornHubAuthHelping
    private let now: @Sendable () -> Date
    private var state: PornHubAuthState = .signedOut
    private var lastValidatedAt: Date?
    private var message: String?
    private var loginTask: Task<Void, Never>?
    private var loginID: UUID?

    public init(store: PornHubCookieStore = KeychainPornHubCookieStore(), helper: PornHubAuthHelping = PornHubAuthHelper(), now: @escaping @Sendable () -> Date = { .now }) {
        self.store = store; self.helper = helper; self.now = now
    }

    public func status() -> PornHubAuthStatus {
        refreshState()
        return authStatus()
    }

    public func login() throws -> PornHubAuthStatus {
        refreshState()
        guard state != .signingIn else { throw PornHubAuthError.signingIn }
        try store.remove()
        state = .signingIn
        message = nil
        let id = UUID()
        loginID = id
        let helper = helper
        loginTask = Task { [weak self] in
            let result: Result<PornHubHelperResult, PornHubAuthError>
            do { result = .success(try await helper.login()) }
            catch let error as PornHubAuthError { result = .failure(error) }
            catch { result = .failure(.helperFailed) }
            await self?.completeLogin(id: id, result: result)
        }
        return authStatus()
    }

    public func cancelLogin() -> PornHubAuthStatus {
        guard state == .signingIn else { return authStatus() }
        loginID = nil
        loginTask?.cancel()
        loginTask = nil
        state = .signedOut
        lastValidatedAt = nil
        message = PornHubAuthError.cancelled.errorDescription
        try? store.remove()
        return authStatus()
    }

    public func logout() async throws -> PornHubAuthStatus {
        try store.remove()
        state = .signedOut
        lastValidatedAt = nil
        message = nil
        loginID = nil
        loginTask?.cancel()
        loginTask = nil
        // The helper uses a nonpersistent data store. Its process-local data is gone when the
        // sign-in window closes, so cleanup is best effort and cannot change signed-out truth.
        try? await helper.logout()
        return PornHubAuthStatus(state: .signedOut)
    }

    public func cookieHeader(for url: URL) throws -> String? {
        let cookies = try PornHubCookieSanitizer.sanitize(store.load(), now: now())
        guard cookies.contains(where: { $0.name == "il" }) else { state = cookies.isEmpty ? .signedOut : .expired; return nil }
        return try PornHubCookieSanitizer.cookieHeader(cookies, for: url, now: now())
    }

    public func regularHomepageCookieHeader(for url: URL) throws -> String? {
        guard state != .signingIn, state != .expired else { return nil }
        do {
            let cookies = try PornHubCookieSanitizer.sanitize(store.load(), now: now())
            guard cookies.contains(where: { $0.name == "il" }) else {
                state = cookies.isEmpty ? .signedOut : .expired
                return nil
            }
            state = .signedIn
            return try PornHubCookieSanitizer.cookieHeader(cookies, for: url, now: now())
        } catch {
            state = .expired
            message = PornHubAuthError.storageUnavailable.errorDescription
            throw PornHubAuthError.storageUnavailable
        }
    }

    public func cookiesForYtDlp() throws -> [PornHubCookieRecord] {
        let cookies = try PornHubCookieSanitizer.sanitize(store.load(), now: now())
        guard cookies.contains(where: { $0.name == "il" }) else { throw PornHubAuthError.signedOut }
        return cookies
    }

    public func recordYtDlpFailure(_ error: PornHubYtDlpError) {
        if error == .sessionExpired { state = .expired }
    }

    private func refreshState(validatedByLogin: Bool = false) {
        guard state != .signingIn || validatedByLogin else { return }
        do {
            let cookies = try PornHubCookieSanitizer.sanitize(store.load(), now: now())
            if cookies.contains(where: { $0.name == "il" }) {
                if state != .expired || validatedByLogin { state = .signedIn }
                if validatedByLogin { lastValidatedAt = now(); message = nil }
            } else {
                state = cookies.isEmpty ? .signedOut : .expired
                lastValidatedAt = nil
            }
        } catch { state = .expired }
    }

    private func completeLogin(id: UUID, result: Result<PornHubHelperResult, PornHubAuthError>) {
        guard loginID == id else { return }
        loginID = nil
        loginTask = nil
        switch result {
        case .success(.signedIn):
            refreshState(validatedByLogin: true)
            if state != .signedIn { state = .signedOut; message = PornHubAuthError.helperFailed.errorDescription }
        case .success(.cancelled):
            try? store.remove()
            state = .signedOut; lastValidatedAt = nil; message = PornHubAuthError.cancelled.errorDescription
        case .success(.signedOut):
            try? store.remove()
            state = .signedOut; lastValidatedAt = nil; message = nil
        case .failure(let error):
            try? store.remove()
            state = .signedOut; lastValidatedAt = nil; message = error.errorDescription
        }
    }

    private func authStatus() -> PornHubAuthStatus {
        PornHubAuthStatus(state: state, lastValidatedAt: lastValidatedAt, message: message)
    }
}

public enum PornHubCookieFile {
    typealias FileWriter = @Sendable (Int32, Data) throws -> Void

    public static func create(in directory: URL, cookies: [PornHubCookieRecord], now: Date = .now) throws -> URL {
        try create(in: directory, cookies: cookies, now: now, filename: nil, fileWriter: nil)
    }

    static func create(in directory: URL, cookies: [PornHubCookieRecord], now: Date, filename: String?, fileWriter: FileWriter?) throws -> URL {
        let sanitized = try PornHubCookieSanitizer.sanitize(cookies, now: now)
        try ensurePrivateDirectory(directory)
        let leaf = filename ?? ".lustre-pornhub-\(UUID().uuidString).cookies"
        guard !leaf.isEmpty, leaf == URL(fileURLWithPath: leaf).lastPathComponent else { throw PornHubAuthError.storageUnavailable }
        let file = directory.appendingPathComponent(leaf)
        let lines = ["# Netscape HTTP Cookie File"] + sanitized.map { cookie in
            let domain = cookie.hostOnly ? cookie.domain : ".\(cookie.domain)"
            let expiry = Int(cookie.expiresAt?.timeIntervalSince1970 ?? 2_147_483_647)
            let includeSubdomains = cookie.hostOnly ? "FALSE" : "TRUE"
            return "\(domain)\t\(includeSubdomains)\t\(cookie.path)\tTRUE\t\(expiry)\t\(cookie.name)\t\(cookie.value)"
        }
        var descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PornHubAuthError.storageUnavailable }
        var removeOnFailure = true
        defer {
            if descriptor >= 0 { _ = close(descriptor) }
            if removeOnFailure { _ = unlink(file.path) }
        }
        try validatePrivateRegularFile(descriptor)
        let write = fileWriter ?? writeAll
        try write(descriptor, Data(lines.joined(separator: "\n").utf8))
        guard fsync(descriptor) == 0 else { throw PornHubAuthError.storageUnavailable }
        try validatePrivateRegularFile(descriptor)
        let closeStatus = close(descriptor)
        descriptor = -1
        guard closeStatus == 0 else { throw PornHubAuthError.storageUnavailable }
        removeOnFailure = false
        return file
    }

    public static func remove(_ file: URL) throws { try FileManager.default.removeItem(at: file) }

    private static func ensurePrivateDirectory(_ directory: URL) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            guard mkdir(directory.path, S_IRWXU) == 0 || errno == EEXIST else { throw PornHubAuthError.storageUnavailable }
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else { throw PornHubAuthError.storageUnavailable }
    }

    private static func validatePrivateRegularFile(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0,
              info.st_nlink == 1 else { throw PornHubAuthError.storageUnavailable }
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw PornHubAuthError.storageUnavailable
                }
                guard written > 0 else { throw PornHubAuthError.storageUnavailable }
                offset += written
            }
        }
    }
}
