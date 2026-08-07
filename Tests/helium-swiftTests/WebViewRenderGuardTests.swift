import XCTest
import WebKit
@testable import Helium

final class WebViewRenderGuardTests: XCTestCase {

    // MARK: - nextLoadAttempt decision table

    func testNavigationFailurePreservesExistingLadder() {
        XCTAssertEqual(
            WebViewRenderGuard.nextLoadAttempt(after: .initialLoad, kind: .navigation, hasBackup: true),
            .secondLoad
        )
        XCTAssertEqual(
            WebViewRenderGuard.nextLoadAttempt(after: .initialLoad, kind: .navigation, hasBackup: false),
            .secondLoad
        )
        XCTAssertEqual(
            WebViewRenderGuard.nextLoadAttempt(after: .secondLoad, kind: .navigation, hasBackup: true),
            .backupLoad
        )
        XCTAssertNil(
            WebViewRenderGuard.nextLoadAttempt(after: .secondLoad, kind: .navigation, hasBackup: false)
        )
    }

    func testJsCrashSkipsRetryWhenBackupExists() {
        XCTAssertEqual(
            WebViewRenderGuard.nextLoadAttempt(after: .initialLoad, kind: .jsCrash, hasBackup: true),
            .backupLoad
        )
    }

    func testJsCrashWithoutBackupStillGetsOneRetry() {
        XCTAssertEqual(
            WebViewRenderGuard.nextLoadAttempt(after: .initialLoad, kind: .jsCrash, hasBackup: false),
            .secondLoad
        )
        XCTAssertNil(
            WebViewRenderGuard.nextLoadAttempt(after: .secondLoad, kind: .jsCrash, hasBackup: false)
        )
    }

    func testBackupLoadIsAlwaysTerminal() {
        for kind: WebViewFailKind in [.navigation, .jsCrash, .processTerminated] {
            XCTAssertNil(
                WebViewRenderGuard.nextLoadAttempt(after: .backupLoad, kind: kind, hasBackup: true),
                "A failure in the fallback bundle must terminate the ladder (kind: \(kind))"
            )
        }
    }

    func testProcessTerminationKeepsFullLadder() {
        XCTAssertEqual(
            WebViewRenderGuard.nextLoadAttempt(after: .initialLoad, kind: .processTerminated, hasBackup: true),
            .secondLoad
        )
        XCTAssertEqual(
            WebViewRenderGuard.nextLoadAttempt(after: .secondLoad, kind: .processTerminated, hasBackup: true),
            .backupLoad
        )
    }

    // MARK: - Fatal window

    func testErrorBeforeContentLoadedIsAlwaysWithinWindow() {
        XCTAssertTrue(
            WebViewRenderGuard.isWithinFatalWindow(isContentLoaded: false, contentLoadedAt: nil)
        )
    }

    func testErrorShortlyAfterContentLoadedIsWithinWindow() {
        let loadedAt = Date()
        XCTAssertTrue(
            WebViewRenderGuard.isWithinFatalWindow(
                isContentLoaded: true,
                contentLoadedAt: loadedAt,
                now: loadedAt.addingTimeInterval(4.9)
            )
        )
    }

    func testLateErrorIsOutsideWindow() {
        let loadedAt = Date()
        XCTAssertFalse(
            WebViewRenderGuard.isWithinFatalWindow(
                isContentLoaded: true,
                contentLoadedAt: loadedAt,
                now: loadedAt.addingTimeInterval(5.1)
            )
        )
    }

    func testContentLoadedWithoutTimestampIsWithinWindow() {
        XCTAssertTrue(
            WebViewRenderGuard.isWithinFatalWindow(isContentLoaded: true, contentLoadedAt: nil)
        )
    }

    // MARK: - Script sources

    func testErrorHookScriptContainsTokenAndGuardedBridge() {
        let source = WebViewRenderGuard.errorHookScriptSource(loadToken: "test-token-123")
        XCTAssertTrue(source.contains("'test-token-123'"))
        XCTAssertTrue(source.contains("window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.logging"))
        XCTAssertTrue(source.contains("addEventListener('error'"))
        XCTAssertTrue(source.contains("addEventListener('unhandledrejection'"))
    }

    // MARK: - Observability event shapes

    private func wireProperties(for event: any HeliumObservabilityEvent) throws -> NSDictionary {
        let json = try SegmentJSON(event.properties)
        let data = try JSONEncoder().encode(json)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testJsErrorDetectedEventShape() throws {
        let event = PaywallJSErrorDetected(
            source: "error",
            errorMessage: "locale.some is not a function",
            errorStack: "TypeError: locale.some is not a function\n  at render",
            loadAttempt: "initialLoad",
            outcome: .fatalBlankScreen,
            msSinceLoadStart: 250
        )

        XCTAssertEqual(event.name, "paywall_js_error_detected")
        XCTAssertEqual(try wireProperties(for: event), NSDictionary(dictionary: [
            "source": "error",
            "loadAttempt": "initialLoad",
            "outcome": "fatalBlankScreen",
            "errorMessage": "locale.some is not a function",
            "errorStack": "TypeError: locale.some is not a function\n  at render",
            "msSinceLoadStart": 250,
        ]))
    }

    func testJsErrorDetectedTruncatesLongStack() throws {
        let event = PaywallJSErrorDetected(
            source: "unhandledrejection",
            errorMessage: nil,
            errorStack: String(repeating: "x", count: 2000),
            loadAttempt: "initialLoad",
            outcome: .benign,
            msSinceLoadStart: nil
        )

        let props = try wireProperties(for: event)
        let stack = try XCTUnwrap(props["errorStack"] as? String)
        XCTAssertTrue(stack.hasSuffix("…(truncated)"))
        XCTAssertLessThan(stack.count, 1100)
        XCTAssertNil(props["errorMessage"])
        XCTAssertNil(props["msSinceLoadStart"])
    }

    func testWebProcessTerminatedEventShape() throws {
        let event = PaywallWebProcessTerminated(loadAttempt: "backupLoad", wasContentLoaded: true)

        XCTAssertEqual(event.name, "paywall_web_process_terminated")
        XCTAssertEqual(try wireProperties(for: event), NSDictionary(dictionary: [
            "loadAttempt": "backupLoad",
            "wasContentLoaded": true,
        ]))
    }

    // MARK: - Logging bridge routing

    private final class FakeScriptMessage: WKScriptMessage {
        private let fakeName: String
        private let fakeBody: Any
        init(name: String, body: Any) {
            self.fakeName = name
            self.fakeBody = body
        }
        override var name: String { fakeName }
        override var body: Any { fakeBody }
    }

    func testJsErrorMessagePostsNotificationWithUserInfo() {
        let handler = WebViewMessageHandler()
        let body: [String: Any] = [
            "type": "js-error",
            "source": "error",
            "message": "boom",
            "stack": "TypeError: boom",
            "loadToken": "tok-1",
        ]

        let notification = expectation(forNotification: .webViewJSErrorDetected, object: handler) { note in
            let info = note.userInfo as? [String: Any]
            return info?["loadToken"] as? String == "tok-1" && info?["message"] as? String == "boom"
        }
        let replied = expectation(description: "replyHandler called")

        handler.userContentController(
            WKUserContentController(),
            didReceive: FakeScriptMessage(name: "logging", body: body)
        ) { _, _ in replied.fulfill() }

        wait(for: [notification, replied], timeout: 1.0)
    }

    func testNonJsErrorLoggingMessagePostsNothing() {
        let handler = WebViewMessageHandler()

        var received = false
        let observer = NotificationCenter.default.addObserver(
            forName: .webViewJSErrorDetected, object: handler, queue: nil
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        let replied = expectation(description: "replyHandler called")
        handler.userContentController(
            WKUserContentController(),
            didReceive: FakeScriptMessage(name: "logging", body: ["level": "debug", "msg": "hi"])
        ) { _, _ in replied.fulfill() }

        wait(for: [replied], timeout: 1.0)
        XCTAssertFalse(received)
    }
}
