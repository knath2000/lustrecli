import AppKit
import Darwin
import Foundation
import WebKit
import LustreAgent

struct LustreAuthHelperMain {
    @MainActor
    static func main() {
        let command = CommandLine.arguments.dropFirst().first
        if command == "allpornstream-verify" || command == "allpornstream-render" {
            let mode: AllPornStreamHelperWindow.Mode
            if command == "allpornstream-verify" {
                mode = .verify
            } else {
                guard let encoded = CommandLine.arguments.dropFirst(2).first,
                      let data = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").paddingBase64),
                      let rawURL = String(data: data, encoding: .utf8),
                      let url = URL(string: rawURL),
                      AllPornStreamPolicy.isTrusted(url)
                else { exit(2) }
                mode = .render(url)
            }
            let app = NSApplication.shared
            if command == "allpornstream-verify" { app.setActivationPolicy(.regular) }
            else { app.setActivationPolicy(.prohibited) }
            let controller = AllPornStreamHelperWindow(mode: mode)
            if command == "allpornstream-verify" {
                controller.showWindow(nil)
                app.activate(ignoringOtherApps: true)
            }
            withExtendedLifetime(controller) { app.run() }
            return
        }
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

private extension String {
    var paddingBase64: String {
        padding(toLength: count + (4 - count % 4) % 4, withPad: "=", startingAt: 0)
    }
}

MainActor.assumeIsolated {
    LustreAuthHelperMain.main()
}

@MainActor private final class HelperWindow: NSWindowController, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver, NSWindowDelegate {
    private let dataStore = WKWebsiteDataStore.nonPersistent()
    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        return view
    }()
    private var validation = PornHubHelperValidationCoordinator()
    private var validationNavigation: WKNavigation?
    private var finished = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Sign in with PornHub"
        super.init(window: window)
        window.delegate = self
        window.contentView = webView
        dataStore.httpCookieStore.add(self)
        webView.load(URLRequest(url: URL(string: "https://www.pornhub.com/login")!))
    }
    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { finish(.cancelled) }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = action.targetFrame?.isMainFrame == true
        let opensNewWindow = action.targetFrame == nil
        decisionHandler(PornHubHelperNavigationPolicy.allows(
            url: action.request.url, isMainFrame: isMainFrame,
            topLevelURL: webView.url,
            opensNewWindow: opensNewWindow, requestsDownload: action.shouldPerformDownload
        ) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(PornHubHelperNavigationPolicy.allowsResponse(
            url: response.response.url,
            isMainFrame: response.isForMainFrame,
            topLevelURL: webView.url,
            canShowMIMEType: response.canShowMIMEType
        ) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if PornHubHelperChallengePolicy.resetsValidation(authenticationMethod: challenge.protectionSpace.authenticationMethod) {
            _ = validation.authenticationChallenge()
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        terminal(navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        terminal(navigation)
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        scheduleCookieValidation()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished, let navigation else { return }
        guard let activeValidationNavigation = validationNavigation, navigation === activeValidationNavigation else {
            scheduleCookieValidation(afterLoginNavigation: webView.url)
            return
        }
        self.validationNavigation = nil
        let action = validation.navigationFinished(url: webView.url)
        guard action == .evaluatePage else {
            handle(action)
            return
        }
        Task { @MainActor in
            do {
                let cookies = try await trustedCookies()
                let hasSessionProofCandidate = PornHubHelperCookieCandidatePolicy.hasSessionProofCandidate(cookies)
                guard hasSessionProofCandidate else { handle(validation.authenticationResult(isAuthenticated: false)); return }
                let pageReportsAuthenticatedUser = try await pageAuthenticationState()
                let authenticated = PornHubAuthenticationValidation.isAuthenticated(PornHubAuthenticationMarkers(
                    hasSessionCookie: hasSessionProofCandidate,
                    pageReportsAuthenticatedUser: pageReportsAuthenticatedUser
                ))
                guard authenticated else { handle(validation.authenticationResult(isAuthenticated: false)); return }
                guard !finished else { return }
                try KeychainPornHubCookieStore().save(cookies)
                finish(.signedIn)
            } catch let error as PornHubAuthError where error == .storageUnavailable {
                finish(.storageUnavailable)
            } catch {
                finish(.helperFailed)
            }
        }
    }

    private enum ResultToken: String { case signedIn = "signed-in", cancelled, signedOut = "signed-out", helperFailed = "helper-failed", storageUnavailable = "storage-unavailable" }

    private func finish(_ token: ResultToken) {
        guard !finished else { return }; finished = true
        dataStore.httpCookieStore.remove(self)
        print(token.rawValue)
        NSApplication.shared.terminate(nil)
    }

    private func scheduleCookieValidation() {
        guard !finished else { return }
        Task { @MainActor in
            do {
                let cookies = try await trustedCookies()
                guard !finished else { return }
                handle(validation.cookieChanged(hasLoginCompletionTrigger: PornHubHelperCookieCandidatePolicy.hasLoginCompletionTrigger(cookies)))
            } catch {
                finish(.helperFailed)
            }
        }
    }

    private func scheduleCookieValidation(afterLoginNavigation url: URL?) {
        guard !finished else { return }
        Task { @MainActor in
            do {
                let cookies = try await trustedCookies()
                guard !finished else { return }
                handle(validation.loginNavigationFinished(
                    url: url,
                    hasLoginCompletionTrigger: PornHubHelperCookieCandidatePolicy.hasLoginCompletionTrigger(cookies)
                ))
            } catch {
                finish(.helperFailed)
            }
        }
    }

    private func trustedCookies() async throws -> [PornHubCookieRecord] {
        let records = await dataStore.httpCookieStore.allCookies()
        return try PornHubHelperCookieCandidatePolicy.sanitizeTrustedCookies(records.map(PornHubWebKitCookieCapture.record))
    }

    private func handle(_ action: PornHubHelperValidationAction) {
        guard !finished else { return }
        switch action {
        case .loadSubscriptions:
            validationNavigation = webView.load(URLRequest(url: URL(string: "https://www.pornhub.com/subscriptions")!))
        case .fail:
            finish(.helperFailed)
        case .none, .evaluatePage:
            break
        }
    }

    private func terminal(_ navigation: WKNavigation?) {
        guard let navigation, let activeValidationNavigation = validationNavigation, navigation === activeValidationNavigation else { return }
        self.validationNavigation = nil
        handle(validation.terminalNavigation())
    }

    private func pageAuthenticationState() async throws -> Bool? {
        let script = """
        (() => {
          if (globalThis.isLoggedInUser === 1) return 1;
          if (globalThis.isLoggedInUser === 0) return 0;
          return -1;
        })()
        """
        guard let value = try await webView.evaluateJavaScript(script) as? NSNumber else {
            throw PornHubAuthError.helperFailed
        }
        switch value.intValue {
        case 1: return true
        case 0: return false
        default: return nil
        }
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
