import AppKit
import Darwin
import Foundation
import WebKit
import LustreAgent

@main
struct LustreAuthHelperMain {
    static func main() {
        let command = CommandLine.arguments.dropFirst().first
        guard command == "login" || command == "logout" else { exit(2) }
        let app = NSApplication.shared
        if command == "logout" {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                await HelperWindow.clearPornHubData()
                FileHandle.standardOutput.write(Data("signed-out\n".utf8))
                fflush(stdout)
                app.terminate(nil)
            }
            app.run()
        } else {
            app.setActivationPolicy(.regular)
            let controller = HelperWindow()
            controller.showWindow(nil)
            app.activate(ignoringOtherApps: true)
            withExtendedLifetime(controller) { app.run() }
        }
    }
}

@MainActor private final class HelperWindow: NSWindowController, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private let dataStore = WKWebsiteDataStore.nonPersistent()
    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        return view
    }()
    private var validating = false
    private var finished = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Sign in with PornHub"
        super.init(window: window)
        window.delegate = self
        window.contentView = webView
        webView.load(URLRequest(url: URL(string: "https://www.pornhub.com/")!))
    }
    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { finish("cancelled") }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = action.targetFrame?.isMainFrame == true
        let opensNewWindow = action.targetFrame == nil
        decisionHandler(PornHubHelperNavigationPolicy.allows(
            url: action.request.url, isMainFrame: isMainFrame,
            opensNewWindow: opensNewWindow, requestsDownload: action.shouldPerformDownload
        ) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(PornHubHelperNavigationPolicy.allowsResponse(
            url: response.response.url, canShowMIMEType: response.canShowMIMEType
        ) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished else { return }
        Task { @MainActor in
            let records = await dataStore.httpCookieStore.allCookies()
            let cookies = records.compactMap(Self.record)
            guard (try? PornHubCookieSanitizer.sanitize(cookies))?.contains(where: { $0.name == "il" }) == true else { return }
            if !validating {
                validating = true
                webView.load(URLRequest(url: URL(string: "https://www.pornhub.com/subscriptions")!))
                return
            }
            let path = webView.url?.path ?? ""
            guard Self.isTrusted(webView.url), path == "/subscriptions" || path.hasPrefix("/subscriptions/") else { return }
            do {
                try KeychainPornHubCookieStore().save(cookies)
                finish("signed-in")
            } catch { finish("cancelled") }
        }
    }

    private func finish(_ token: String) {
        guard !finished else { return }; finished = true
        print(token)
        NSApplication.shared.terminate(nil)
    }

    private static func record(_ cookie: HTTPCookie) -> PornHubCookieRecord? {
        PornHubCookieRecord(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, expiresAt: cookie.expiresDate, secure: cookie.isSecure)
    }

    static func clearPornHubData() async {
        // Each helper process owns a fresh nonpersistent store. There is no persistent WebKit
        // state to erase here; this only clears data created in this short-lived process.
        let store = WKWebsiteDataStore.nonPersistent()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let matching = records.filter { PornHubCookieSanitizer.isAllowedDomain($0.displayName) }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching)
    }

    private static func isTrusted(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return PornHubCookieSanitizer.isAllowedDomain(host)
    }
}
