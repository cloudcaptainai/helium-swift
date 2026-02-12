//
//  HeliumFallbackUITests.swift
//  HeliumExampleUITests
//
//  Verifies that the fallback paywall renders in three failure scenarios:
//  download failure, loading budget timeout, and invalid trigger.
//

import XCTest

final class HeliumFallbackUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Creates a configured XCUIApplication with env vars passed from CI
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UI_TESTING_PURCHASE", "AUTO_FETCH"]

        // Pass env vars from CI to the app
        if let apiKey = ProcessInfo.processInfo.environment["HELIUM_API_KEY"] {
            app.launchEnvironment["HELIUM_API_KEY"] = apiKey
        }
        if let triggerKey = ProcessInfo.processInfo.environment["HELIUM_TRIGGER_KEY"] {
            app.launchEnvironment["HELIUM_TRIGGER_KEY"] = triggerKey
        }

        return app
    }

    // MARK: - Fallback Paywall Tests

    @MainActor
    func testFallbackPaywallOnDownloadFailure() throws {
        let app = makeApp()
        app.launchEnvironment["FALLBACK_TEST_MODE"] = "download_failure"
        app.launch()
        sleep(2) // Let CI simulator stabilize

        // Paywall is auto-presented on launch with an invalid API key.
        // Config fetch fails → fallback paywall (webview) should appear.
        let webView = app.webViews.firstMatch
        XCTAssert(webView.waitForExistence(timeout: 15), "Fallback paywall WebView did not appear after download failure")
    }

    @MainActor
    func testFallbackPaywallOnLoadingBudgetExpired() throws {
        let app = makeApp()
        app.launchEnvironment["FALLBACK_TEST_MODE"] = "loading_budget"
        app.launch()
        sleep(2) // Let CI simulator stabilize

        // Paywall is auto-presented on launch with a 1s loading budget.
        // Budget expires before downloads complete → fallback paywall should appear.
        let webView = app.webViews.firstMatch
        XCTAssert(webView.waitForExistence(timeout: 10), "Fallback paywall WebView did not appear after loading budget expired")
    }

    @MainActor
    func testFallbackPaywallOnInvalidTrigger() throws {
        let app = makeApp()
        app.launch()
        sleep(2) // Let CI simulator stabilize

        // Wait for downloads to complete, then tap the invalid trigger button
        let triggerButton = app.buttons.matching(identifier: "presentFallbackInvalidTrigger").firstMatch
        XCTAssert(triggerButton.waitForExistence(timeout: 10), "Invalid trigger button not found")
        triggerButton.tap()

        // No paywall exists for this trigger → fallback paywall (webview) should appear
        let webView = app.webViews.firstMatch
        XCTAssert(webView.waitForExistence(timeout: 15), "Fallback paywall WebView did not appear for invalid trigger")
    }
}
