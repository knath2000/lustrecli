import Foundation
import LustreCore

enum PornHubFeedRequest {
    static func fetch(_ url: URL, headers: [String: String]) async throws -> HTTPPage {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let cookie = PornHubFeedRedirectPolicy.cookieHeader(for: url, suppliedCookie: headers["Cookie"])
        let delegate = RedirectDelegate(cookie: cookie)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        headers.filter { $0.key.caseInsensitiveCompare("Cookie") != .orderedSame }.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = response.url,
              let body = String(data: data, encoding: .utf8) else { throw FeedError.network(0) }
        return HTTPPage(body: body, finalURL: finalURL, statusCode: http.statusCode)
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let cookie: String?
        init(cookie: String?) { self.cookie = cookie }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard PornHubFeedRedirectPolicy.allowsRedirect(to: request.url) else {
                completionHandler(nil); return
            }
            var safe = request
            safe.httpShouldHandleCookies = false
            safe.setValue(nil, forHTTPHeaderField: "Cookie")
            if let cookie { safe.setValue(cookie, forHTTPHeaderField: "Cookie") }
            completionHandler(safe)
        }
    }
}

enum PornHubFeedRedirectPolicy {
    static func cookieHeader(for url: URL, suppliedCookie: String?) -> String? {
        guard allowsCookie(for: url), let suppliedCookie, !suppliedCookie.isEmpty else { return nil }
        return suppliedCookie
    }

    static func allowsRedirect(to url: URL?) -> Bool {
        guard let url else { return false }
        return allowsCookie(for: url)
    }

    private static func allowsCookie(for url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host else { return false }
        return PornHubCookieSanitizer.isAllowedDomain(host)
    }
}
