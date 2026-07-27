import AppKit
import Darwin
import Foundation
import WebKit
import LustreAgent

@MainActor final class AllPornStreamHelperWindow: NSWindowController, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    enum Mode {
        case verify
        case render(URL)
    }

    private let mode: Mode
    private let dataStore = WKWebsiteDataStore.nonPersistent()
    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        return view
    }()
    private var finished = false

    init(mode: Mode) {
        self.mode = mode
        let visible: Bool
        switch mode { case .verify: visible = true; case .render: visible = false }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720), styleMask: visible ? [.titled, .closable, .miniaturizable] : [.borderless], backing: .buffered, defer: false)
        window.title = "Verify AllPornStream"
        super.init(window: window)
        window.delegate = self
        window.contentView = webView
        Task { @MainActor in
            do {
                for record in try AllPornStreamCookieStore().load() {
                    guard let cookie = HTTPCookie(properties: [
                        .name: record.name,
                        .value: record.value,
                        .domain: record.hostOnly ? record.domain : ".\(record.domain)",
                        .path: record.path,
                        .secure: "TRUE",
                        .expires: record.expiresAt as Any,
                    ]) else { continue }
                    await dataStore.httpCookieStore.setCookie(cookie)
                }
                let url: URL
                switch mode {
                case .verify: url = URL(string: "https://allpornstream.com")!
                case let .render(target): url = target
                }
                webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            } catch {
                finish("helper-failed", status: 1)
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        guard case .verify = mode else { return }
        finish("cancelled", status: 1)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = action.targetFrame != nil && !action.shouldPerformDownload && AllPornStreamPolicy.isTrusted(action.request.url)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType && AllPornStreamPolicy.isTrusted(response.response.url) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish("helper-failed", status: 1)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish("helper-failed", status: 1)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished, AllPornStreamPolicy.isTrusted(webView.url) else {
            finish("helper-failed", status: 1)
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            guard !finished else { return }
            do {
                let value = try await webView.evaluateJavaScript("document.documentElement.outerHTML")
                guard let html = value as? String,
                      let data = html.data(using: .utf8),
                      data.count <= AllPornStreamPolicy.maximumRenderedHTMLBytes
                else { finish("helper-failed", status: 1); return }
                let challenged = html.localizedCaseInsensitiveContains("Just a moment") || html.contains("cf-chl-") || html.contains("challenge-platform")
                if challenged {
                    if case .render = mode { finish("verification-required", status: 0) }
                    return
                }
                let records = await dataStore.httpCookieStore.allCookies().map(PornHubWebKitCookieCapture.record)
                try AllPornStreamCookieStore().save(AllPornStreamPolicy.sanitize(records))
                switch mode {
                case .verify:
                    finish("verified", status: 0)
                case .render:
                    let output = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                    finish(output, status: 0)
                }
            } catch {
                finish("helper-failed", status: 1)
            }
        }
    }

    private func finish(_ output: String, status: Int32) {
        guard !finished else { return }
        finished = true
        FileHandle.standardOutput.write(Data("\(output)\n".utf8))
        fflush(stdout)
        if status != 0 { Darwin.exit(status) }
        NSApplication.shared.terminate(nil)
    }
}
