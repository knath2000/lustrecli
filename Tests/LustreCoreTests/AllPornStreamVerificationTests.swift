import XCTest
@testable import LustreAgent

final class AllPornStreamVerificationTests: XCTestCase {
    func testNavigationAllowsOnlyCredentialFreeHTTPSProviderPages() {
        XCTAssertTrue(AllPornStreamPolicy.isTrusted(URL(string: "https://allpornstream.com/?search=test")))
        XCTAssertTrue(AllPornStreamPolicy.isTrusted(URL(string: "https://www.allpornstream.com/page/2")))
        XCTAssertFalse(AllPornStreamPolicy.isTrusted(URL(string: "http://allpornstream.com")))
        XCTAssertFalse(AllPornStreamPolicy.isTrusted(URL(string: "https://allpornstream.com.evil.example")))
        XCTAssertFalse(AllPornStreamPolicy.isTrusted(URL(string: "https://user:secret@allpornstream.com")))
    }

    func testCookieSanitizerKeepsOnlyBoundedProviderClearance() throws {
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let cookies = [
            PornHubCookieRecord(name: "cf_clearance", value: "safe", domain: ".allpornstream.com", path: "/", expiresAt: expiry, secure: true, hostOnly: false),
            PornHubCookieRecord(name: "session", value: "secret", domain: ".allpornstream.com", path: "/", expiresAt: expiry, secure: true, hostOnly: false),
            PornHubCookieRecord(name: "__cf_bm", value: "foreign", domain: ".evil.example", path: "/", expiresAt: expiry, secure: true, hostOnly: false),
        ]
        XCTAssertEqual(try AllPornStreamPolicy.sanitize(cookies, now: .distantPast).map(\.name), ["cf_clearance"])
    }
}
