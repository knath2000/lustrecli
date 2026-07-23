import Darwin
import Security
import XCTest
@testable import LustreAgent
@testable import LustreCore

final class PornHubAuthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_000_000)
    private let secret = "synthetic-session-value"

    func testCookieSanitizerRoundTripsAndDropsIncidentalCookiesWithinBoundedInput() throws {
        let active = cookie(name: "il", domain: ".pornhub.com", path: "/")
        let dropped = [
            cookie(name: "expired", domain: ".pornhub.com", expiresAt: now.addingTimeInterval(-1)),
            cookie(name: "external", domain: "example.test"),
            cookie(name: "insecure", domain: ".pornhub.com", secure: false)
        ]
        let sanitized = try PornHubCookieSanitizer.sanitize([active] + dropped, now: now)
        XCTAssertEqual(try JSONDecoder().decode([PornHubCookieRecord].self, from: JSONEncoder().encode(sanitized)), sanitized)
        XCTAssertEqual(sanitized.map(\.name), ["il"])
        XCTAssertThrowsError(try PornHubCookieSanitizer.sanitize([cookie(name: "bad\tname", domain: ".pornhub.com")], now: now))
        XCTAssertThrowsError(try PornHubCookieSanitizer.sanitize([cookie(name: "il", domain: ".pornhub.com", value: String(repeating: "x", count: 4097))], now: now))
        XCTAssertThrowsError(try PornHubCookieSanitizer.sanitize(Array(repeating: cookie(name: "external", domain: "example.test"), count: PornHubCookieSanitizer.maximumCookies + 1), now: now))
        XCTAssertThrowsError(try PornHubCookieSanitizer.sanitize([cookie(name: "external", domain: "example.test", value: String(repeating: "x", count: PornHubCookieSanitizer.maximumAggregateBytes))], now: now))
    }

    func testCookieHeaderUsesRFCPathDomainAndSecureMatchingWithDeterministicOrdering() throws {
        let root = cookie(name: "root", domain: ".pornhub.com", path: "/")
        let account = cookie(name: "account", domain: ".pornhub.com", path: "/account")
        let accountChild = cookie(name: "child", domain: ".pornhub.com", path: "/account/")
        let hostOnly = cookie(name: "host", domain: "www.pornhub.com", hostOnly: true)
        let expired = cookie(name: "expired", domain: ".pornhub.com", expiresAt: now.addingTimeInterval(-1))
        let cookies = [root, account, accountChild, hostOnly, expired]

        XCTAssertEqual(try PornHubCookieSanitizer.cookieHeader(cookies, for: URL(string: "https://www.pornhub.com/account/profile")!, now: now), "child=synthetic-session-value; account=synthetic-session-value; host=synthetic-session-value; root=synthetic-session-value")
        XCTAssertEqual(try PornHubCookieSanitizer.cookieHeader(cookies, for: URL(string: "https://www.pornhub.com/account")!, now: now), "account=synthetic-session-value; host=synthetic-session-value; root=synthetic-session-value")
        XCTAssertEqual(try PornHubCookieSanitizer.cookieHeader(cookies, for: URL(string: "https://www.pornhub.com/accounting")!, now: now), "host=synthetic-session-value; root=synthetic-session-value")
        XCTAssertEqual(try PornHubCookieSanitizer.cookieHeader(cookies, for: URL(string: "https://www.pornhub.com/subscriptions")!, now: now), "host=synthetic-session-value; root=synthetic-session-value")
        XCTAssertEqual(try PornHubCookieSanitizer.cookieHeader(cookies, for: URL(string: "https://api.pornhub.com/subscriptions")!, now: now), "root=synthetic-session-value")
        XCTAssertNil(try PornHubCookieSanitizer.cookieHeader(cookies, for: URL(string: "http://www.pornhub.com/account")!, now: now))
    }

    func testKeychainLoadOnlyTreatsNotFoundAsSignedOut() throws {
        let missing = KeychainPornHubCookieStore(backend: FakeKeychainBackend(loadStatus: errSecItemNotFound))
        XCTAssertEqual(try missing.load(), [])
        let unavailable = KeychainPornHubCookieStore(backend: FakeKeychainBackend(loadStatus: errSecAuthFailed))
        XCTAssertThrowsError(try unavailable.load()) { XCTAssertEqual($0 as? PornHubAuthError, .storageUnavailable) }
    }

    func testAuthStateAndCookieHeaderNeverExposeCookieMetadata() async throws {
        let store = FakeCookieStore()
        let fixedNow = now
        let service = PornHubAuthService(store: store, helper: FakeHelper(result: .signedIn), now: { fixedNow })
        let initial = await service.status()
        XCTAssertEqual(initial.state, .signedOut)
        try store.save([cookie(name: "il", domain: ".pornhub.com")])
        let status = await service.status()
        XCTAssertEqual(status.state, .signedIn)
        let encoded = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains("il"))
        let authenticatedHeader = try await service.cookieHeader(for: URL(string: "https://www.pornhub.com/subscriptions")!)
        let externalHeader = try await service.cookieHeader(for: URL(string: "https://cdn.example.test/file")!)
        XCTAssertEqual(authenticatedHeader, "il=\(secret)")
        XCTAssertNil(externalHeader)
    }

    func testLogoutIsTruthfullySignedOutAfterKeychainDeletionWhenHelperCleanupFails() async throws {
        let store = FakeCookieStore()
        try store.save([cookie(name: "il", domain: ".pornhub.com")])
        let helper = FakeHelper(result: .signedOut, logoutError: PornHubAuthError.helperFailed)
        let fixedNow = now
        let service = PornHubAuthService(store: store, helper: helper, now: { fixedNow })
        let logoutStatus = try await service.logout()
        XCTAssertEqual(logoutStatus.state, .signedOut)
        let status = await service.status()
        XCTAssertEqual(status.state, .signedOut)
        let didAttemptLogout = await helper.didAttemptLogout()
        XCTAssertTrue(didAttemptLogout)
    }

    func testConcurrentLoginRejectsSecondWindow() async throws {
        let helper = BlockingHelper()
        let fixedNow = now
        let service = PornHubAuthService(store: FakeCookieStore(), helper: helper, now: { fixedNow })
        let first = Task { try await service.login() }
        await helper.waitUntilStarted()
        await XCTAssertThrowsErrorAsync(try await service.login()) { XCTAssertEqual($0 as? PornHubAuthError, .signingIn) }
        await helper.finish(.cancelled)
        await XCTAssertThrowsErrorAsync(try await first.value)
    }

    func testSuccessfulLoginRevalidatesStoredSessionAndRecordsValidationTime() async throws {
        let store = FakeCookieStore()
        try store.save([cookie(name: "il", domain: ".pornhub.com")])
        let fixedNow = now
        let service = PornHubAuthService(store: store, helper: FakeHelper(result: .signedIn), now: { fixedNow })

        let status = try await service.login()

        XCTAssertEqual(status.state, .signedIn)
        XCTAssertEqual(status.lastValidatedAt, now)
    }

    func testCookieFileIsExclusivePrivateAndCleansUpOnWriteFailure() throws {
        let root = temporaryDirectory()
        let cookies = [cookie(name: "il", domain: ".pornhub.com")]
        let file = try PornHubCookieFile.create(in: root, cookies: cookies, now: now, filename: "fixed.cookies", fileWriter: nil)
        XCTAssertEqual(((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077, 0)
        XCTAssertTrue(try String(contentsOf: file).contains(secret))
        XCTAssertThrowsError(try PornHubCookieFile.create(in: root, cookies: cookies, now: now, filename: "fixed.cookies", fileWriter: nil))
        XCTAssertThrowsError(try PornHubCookieFile.create(in: root, cookies: cookies, now: now, filename: "partial.cookies", fileWriter: { _, _ in throw TestWriteFailure.failed }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("partial.cookies").path))
        XCTAssertThrowsError(try PornHubCookieFile.create(in: root, cookies: [cookie(name: "il", domain: ".pornhub.com", value: "contains\ttab")], now: now))
        try PornHubCookieFile.remove(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRedirectAndNavigationPoliciesDenyCookieLeaksAndUnsafeWebKitNavigation() {
        let cookie = "il=synthetic-session-value"
        XCTAssertEqual(PornHubFeedRedirectPolicy.cookieHeader(for: URL(string: "https://www.pornhub.com/subscriptions")!, suppliedCookie: cookie), cookie)
        XCTAssertNil(PornHubFeedRedirectPolicy.cookieHeader(for: URL(string: "https://pornhub.com.evil.test/")!, suppliedCookie: cookie))
        XCTAssertFalse(PornHubFeedRedirectPolicy.allowsRedirect(to: URL(string: "http://www.pornhub.com/")))
        XCTAssertFalse(PornHubFeedRedirectPolicy.allowsRedirect(to: URL(string: "https://evil.test/")))
        XCTAssertTrue(PornHubHelperNavigationPolicy.allows(url: URL(string: "https://www.pornhub.com/login")!, isMainFrame: true, opensNewWindow: false, requestsDownload: false))
        for raw in ["http://www.pornhub.com/", "file:///tmp/a", "data:text/html,test", "javascript:alert(1)", "https://pornhub.com.evil.test/"] {
            XCTAssertFalse(PornHubHelperNavigationPolicy.allows(url: URL(string: raw)!, isMainFrame: true, opensNewWindow: false, requestsDownload: false))
        }
        XCTAssertFalse(PornHubHelperNavigationPolicy.allows(url: URL(string: "https://www.pornhub.com/")!, isMainFrame: false, opensNewWindow: false, requestsDownload: false))
        XCTAssertFalse(PornHubHelperNavigationPolicy.allows(url: URL(string: "https://www.pornhub.com/")!, isMainFrame: true, opensNewWindow: true, requestsDownload: false))
        XCTAssertFalse(PornHubHelperNavigationPolicy.allows(url: URL(string: "https://www.pornhub.com/")!, isMainFrame: true, opensNewWindow: false, requestsDownload: true))
    }

    func testHelperOutputCapAndTimeoutTerminateChild() async throws {
        let root = temporaryDirectory()
        let agent = root.appendingPathComponent("lustre-agent")
        try Data("agent".utf8).write(to: agent)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
        let helper = root.appendingPathComponent("lustre-auth-helper")
        try Data("#!/bin/sh\nprintf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        await XCTAssertThrowsErrorAsync(try await PornHubAuthHelper(executableURL: agent, timeout: 1).login()) { XCTAssertEqual($0 as? PornHubAuthError, .helperFailed) }
        let oversizedStderr = String(repeating: "e", count: 257)
        try Data("#!/bin/sh\nprintf '\(oversizedStderr)' >&2\n".utf8).write(to: helper)
        await XCTAssertThrowsErrorAsync(try await PornHubAuthHelper(executableURL: agent, timeout: 1).login()) { XCTAssertEqual($0 as? PornHubAuthError, .helperFailed) }
        let pidFile = root.appendingPathComponent("child.pid")
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\nsleep 10\nprintf signed-in\n".utf8).write(to: helper)
        await XCTAssertThrowsErrorAsync(try await PornHubAuthHelper(executableURL: agent, timeout: 0.25).login()) { XCTAssertEqual($0 as? PornHubAuthError, .timeout) }
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32((try String(contentsOf: pidFile)).trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<20 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    private func cookie(name: String, domain: String, path: String = "/", expiresAt: Date? = nil, secure: Bool = true, hostOnly: Bool = false, value: String? = nil) -> PornHubCookieRecord {
        PornHubCookieRecord(name: name, value: value ?? secret, domain: domain, path: path, expiresAt: expiresAt, secure: secure, hostOnly: hostOnly)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lustre-auth-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private enum TestWriteFailure: Error { case failed }

private final class FakeKeychainBackend: PornHubKeychainBackend, @unchecked Sendable {
    let loadStatus: OSStatus
    init(loadStatus: OSStatus) { self.loadStatus = loadStatus }
    func copyMatching(service: String, account: String) -> (OSStatus, Data?) { (loadStatus, nil) }
    func update(_ data: Data, service: String, account: String) -> OSStatus { errSecSuccess }
    func add(_ data: Data, service: String, account: String) -> OSStatus { errSecSuccess }
    func remove(service: String, account: String) -> OSStatus { errSecSuccess }
}

private final class FakeCookieStore: PornHubCookieStore, @unchecked Sendable {
    private var cookies: [PornHubCookieRecord] = []
    func load() throws -> [PornHubCookieRecord] { cookies }
    func save(_ cookies: [PornHubCookieRecord]) throws { self.cookies = cookies }
    func remove() throws { cookies = [] }
}

private actor FakeHelper: PornHubAuthHelping {
    let result: PornHubHelperResult
    let logoutError: Error?
    private var logoutAttempted = false
    init(result: PornHubHelperResult, logoutError: Error? = nil) { self.result = result; self.logoutError = logoutError }
    func login() async throws -> PornHubHelperResult { result }
    func logout() async throws { logoutAttempted = true; if let logoutError { throw logoutError } }
    func didAttemptLogout() -> Bool { logoutAttempted }
}

private actor BlockingHelper: PornHubAuthHelping {
    private var continuation: CheckedContinuation<PornHubHelperResult, Never>?
    private var started = false
    func login() async throws -> PornHubHelperResult { started = true; return await withCheckedContinuation { continuation = $0 } }
    func logout() async throws {}
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func finish(_ result: PornHubHelperResult) { continuation?.resume(returning: result); continuation = nil }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ verify: ((Error) -> Void)? = nil) async {
    do { _ = try await expression(); XCTFail("Expected an error") } catch { verify?(error) }
}
