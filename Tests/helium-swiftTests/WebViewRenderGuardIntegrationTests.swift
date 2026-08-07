import XCTest
import WebKit
@testable import Helium

/// Exercises the injected error hook and blank-screen probe against real
/// WebKit: a bundle that throws during initial execution must produce a
/// js-error message on the logging bridge, and the probe must distinguish a
/// blank document from one with visible content.
@MainActor
final class WebViewRenderGuardIntegrationTests: XCTestCase {

    override func setUp() async throws {
        // WebKit page loads can exceed the didFinish timeout under Thread Sanitizer.
        let tsanActive = dlsym(dlopen(nil, RTLD_LAZY), "__tsan_init") != nil
        try XCTSkipIf(tsanActive, "Skipped under Thread Sanitizer: WebKit loads time out")
    }

    private final class LoggingBridgeStub: NSObject, WKScriptMessageHandlerWithReply {
        var onMessage: ((Any) -> Void)?
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            onMessage?(message.body)
            replyHandler(nil, nil)
        }
    }

    private final class NavigationFinishStub: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish?()
        }
    }

    private var bridge: LoggingBridgeStub!
    private var navDelegate: NavigationFinishStub!

    private func makeWebView(loadToken: String) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        bridge = LoggingBridgeStub()
        contentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "logging")
        contentController.addUserScript(WKUserScript(
            source: WebViewRenderGuard.errorHookScriptSource(loadToken: loadToken),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController = contentController
        // A zero frame gives the page a zero viewport, which would make every
        // document probe as blank.
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        navDelegate = NavigationFinishStub()
        webView.navigationDelegate = navDelegate
        return webView
    }

    private enum LoadError: Error { case didFinishTimedOut }

    /// Throws on timeout so a slow load fails here, not as a confusing
    /// follow-on JS error in the assertion that assumed a loaded page.
    private func loadAndWaitForFinish(_ webView: WKWebView, html: String) async throws {
        let finished = expectation(description: "didFinish")
        navDelegate.onFinish = { finished.fulfill() }
        webView.loadHTMLString(html, baseURL: nil)
        guard await XCTWaiter.fulfillment(of: [finished], timeout: 30.0) == .completed else {
            throw LoadError.didFinishTimedOut
        }
    }

    func testThrowDuringInitialExecutionReportsJsErrorWithToken() {
        let webView = makeWebView(loadToken: "integration-tok")

        let reported = expectation(description: "js-error reported")
        bridge.onMessage = { body in
            guard let dict = body as? [String: Any],
                  dict["type"] as? String == "js-error" else { return }
            XCTAssertEqual(dict["loadToken"] as? String, "integration-tok")
            XCTAssertEqual(dict["source"] as? String, "error")
            // loadHTMLString(baseURL: nil) gives the page an opaque origin, so
            // WebKit may sanitize the message to "Script error." — detection,
            // not message fidelity, is what's under test.
            XCTAssertFalse((dict["message"] as? String ?? "").isEmpty)
            reported.fulfill()
        }

        webView.loadHTMLString(
            "<html><body><script>window.locale = {}; locale.some(function(l) { return true; });</script></body></html>",
            baseURL: nil
        )
        wait(for: [reported], timeout: 10.0)
    }

    func testUnhandledRejectionReportsJsError() {
        let webView = makeWebView(loadToken: "rejection-tok")

        let reported = expectation(description: "unhandledrejection reported")
        bridge.onMessage = { body in
            guard let dict = body as? [String: Any],
                  dict["type"] as? String == "js-error" else { return }
            XCTAssertEqual(dict["source"] as? String, "unhandledrejection")
            reported.fulfill()
        }

        webView.loadHTMLString(
            "<html><body><div>visible</div><script>Promise.reject(new Error('async boom'));</script></body></html>",
            baseURL: nil
        )
        wait(for: [reported], timeout: 10.0)
    }

    func testProbeReturnsBlankForCrashedEmptyDocument() async throws {
        let webView = makeWebView(loadToken: "probe-blank-tok")
        try await loadAndWaitForFinish(
            webView,
            html: "<html><body><script>window.locale = {}; locale.some(function(l) { return true; });</script></body></html>"
        )

        let result = try await webView.evaluateJavaScript(WebViewRenderGuard.blankScreenProbeSource)
        XCTAssertEqual(result as? String, "blank")
    }

    func testProbeReturnsContentForVisibleText() async throws {
        let webView = makeWebView(loadToken: "probe-content-tok")
        try await loadAndWaitForFinish(
            webView,
            html: "<html><body><div>Start your free trial</div></body></html>"
        )

        let result = try await webView.evaluateJavaScript(WebViewRenderGuard.blankScreenProbeSource)
        XCTAssertEqual(result as? String, "content")
    }

    func testProbeReturnsContentForDirectBodyText() async throws {
        let webView = makeWebView(loadToken: "probe-body-text-tok")
        try await loadAndWaitForFinish(
            webView,
            html: "<html><body>Paywall ready</body></html>"
        )

        let result = try await webView.evaluateJavaScript(WebViewRenderGuard.blankScreenProbeSource)
        XCTAssertEqual(result as? String, "content")
    }

    func testHookScriptDoesNotBreakWorkingPage() async throws {
        let webView = makeWebView(loadToken: "no-interference-tok")

        var reportedError = false
        bridge.onMessage = { _ in reportedError = true }

        try await loadAndWaitForFinish(
            webView,
            html: "<html><body><div id='root'>Paywall</div><script>document.getElementById('root').textContent = 'Paywall ready';</script></body></html>"
        )

        let text = try await webView.evaluateJavaScript("document.getElementById('root').textContent")
        XCTAssertEqual(text as? String, "Paywall ready")
        XCTAssertFalse(reportedError)
    }
}
