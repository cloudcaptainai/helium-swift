//
//  HeliumExampleUITests.swift
//  HeliumExampleUITests
//
//  Created by Kyle Gorlick on 1/5/26.
//

import XCTest

final class HeliumExampleUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Creates a configured XCUIApplication with env vars passed from CI
    private func makeApp(restoreSuccess: Bool? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UI_TESTING_PURCHASE", "AUTO_FETCH"]

        if let restoreSuccess {
            app.launchArguments.append(restoreSuccess ? "UI_TESTING_RESTORE_SUCCESS" : "UI_TESTING_RESTORE_FAIL")
        }

        // Pass env vars from CI to the app
        if let apiKey = ProcessInfo.processInfo.environment["HELIUM_API_KEY"] {
            app.launchEnvironment["HELIUM_API_KEY"] = apiKey
        }
        if let triggerKey = ProcessInfo.processInfo.environment["HELIUM_TRIGGER_KEY"] {
            app.launchEnvironment["HELIUM_TRIGGER_KEY"] = triggerKey
        }

        // Ensure this is cleared
        app.launchEnvironment["LOAD_STATE_TEST_TRIGGER"] = nil

        return app
    }

    func testAPIKeysAreNotEmpty() {
        XCTAssertFalse((ProcessInfo.processInfo.environment["HELIUM_API_KEY"] ?? "").isEmpty, "HELIUM_API_KEY should not be empty")
        XCTAssertFalse((ProcessInfo.processInfo.environment["HELIUM_TRIGGER_KEY"] ?? "").isEmpty, "HELIUM_TRIGGER_KEY should not be empty")
    }

    @MainActor
    func testPurchase() throws {
        let app = makeApp()
        app.launch()
        sleep(2) // Let CI simulator stabilize
        
        let triggerButton = app.buttons.matching(identifier: "presentPaywall").firstMatch
        triggerButton.tap()
        
        // Wait for the webview to load
        let webView = app.webViews.firstMatch
        XCTAssert(webView.waitForExistence(timeout: 30), "Paywall WebView did not appear")
        sleep(2) // Buffer for WebView to finish rendering
        
        let purchaseFeedbackIndicator = app.staticTexts["makePurchaseCalled"]
        XCTAssert(purchaseFeedbackIndicator.waitForExistence(timeout: 10), "makePurchase method was not called")
        
        // Ensure proper dismissal
        XCTAssert(webView.waitForNonExistence(timeout: 5), "Not properly dismissed after purchase.")
    }
    
    @MainActor
    func testModifierDisplayAndDismiss() throws {
        let app = makeApp()
        app.launch()
        sleep(2) // Let CI simulator stabilize
        
        let triggerButton = app.buttons.matching(identifier: "showPaywallViaModifier").firstMatch
        triggerButton.tap()
        
        // Wait for the webview to load
        let webView = app.webViews.firstMatch
        XCTAssert(webView.waitForExistence(timeout: 30), "Paywall WebView did not appear")
        sleep(2) // Buffer for WebView to finish rendering
                
        // Close the paywall
        let closeButton = webView.buttons["Close"].firstMatch
        XCTAssert(closeButton.waitForExistence(timeout: 15), "Close button not found")
        closeButton.tap()
        
        // Ensure proper dismissal
        XCTAssert(webView.waitForNonExistence(timeout: 10), "Not properly dismissed after purchase.")
    }
    
    @MainActor
    func testLoadingStateThenPaywall() throws {
        let app = makeApp()
        let trigger = ProcessInfo.processInfo.environment["HELIUM_TRIGGER_KEY"] ?? "ci_annual_monthly"
        app.launchEnvironment["LOAD_STATE_TEST_TRIGGER"] = trigger
        app.launch()
        sleep(2) // Let CI simulator stabilize

        // Paywall loading state should automatically be opened and then show content once paywalls download
        
        // Wait for the webview to load
        let webView = app.webViews.firstMatch
        XCTAssert(webView.waitForExistence(timeout: 40), "Paywall WebView did not appear")
        sleep(2) // Buffer for WebView to finish rendering
        
        let purchaseFeedbackIndicator = app.staticTexts["makePurchaseCalled"]
        XCTAssert(purchaseFeedbackIndicator.waitForExistence(timeout: 10), "makePurchase method was not called")
        
        // Ensure proper dismissal
        XCTAssert(webView.waitForNonExistence(timeout: 5), "Not properly dismissed after purchase.")
    }

    // MARK: - Restore Purchase Tests

    @MainActor
    func testRestorePurchaseFailureShowsAlert() throws {
        let app = makeApp(restoreSuccess: false)
        app.launch()
        sleep(2)

        let triggerButton = app.buttons.matching(identifier: "presentPaywall").firstMatch
        triggerButton.tap()

        let webView = app.webViews.firstMatch
        XCTAssert(webView.waitForExistence(timeout: 30), "Paywall WebView did not appear")
        sleep(2)

        // Look for a restore purchases link/button in the WebView
        let restoreButton = webView.buttons["Restore Purchases"].firstMatch
        guard restoreButton.waitForExistence(timeout: 10) else {
            // If no restore button found, skip - this paywall may not have one
            throw XCTSkip("Restore Purchases button not found in this paywall configuration")
        }
        restoreButton.tap()

        // Helium shows an alert dialog when restore fails
        let alert = app.alerts.firstMatch
        XCTAssert(alert.waitForExistence(timeout: 10), "Restore failure alert did not appear")
    }

    @MainActor
    func testRestorePurchaseSuccessClosesPaywall() throws {
        let app = makeApp(restoreSuccess: true)
        app.launch()
        sleep(2)

        let triggerButton = app.buttons.matching(identifier: "presentPaywall").firstMatch
        triggerButton.tap()

        let webView = app.webViews.firstMatch
        XCTAssert(webView.waitForExistence(timeout: 30), "Paywall WebView did not appear")
        sleep(2)

        let restoreButton = webView.buttons["Restore Purchases"].firstMatch
        guard restoreButton.waitForExistence(timeout: 10) else {
            throw XCTSkip("Restore Purchases button not found in this paywall configuration")
        }
        restoreButton.tap()

        // Paywall should dismiss after successful restore
        XCTAssert(webView.waitForNonExistence(timeout: 10), "Paywall did not dismiss after successful restore")
    }

}
