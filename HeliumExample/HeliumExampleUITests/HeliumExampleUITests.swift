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
        
        let subscribeButton = webView.buttons["START MY FREE TRIAL"].firstMatch
        XCTAssert(subscribeButton.waitForExistence(timeout: 15), "Subscribe button not found")
        
        subscribeButton.tap()
        
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
        
        // Ensure webview properly displays
        let subscribeButton = webView.buttons["START MY FREE TRIAL"].firstMatch
        XCTAssert(subscribeButton.waitForExistence(timeout: 15), "Subscribe button not found")
        
        // Close the paywall
        let closeButton = webView.buttons["Close"].firstMatch
        XCTAssert(closeButton.waitForExistence(timeout: 15), "Close button not found")
        closeButton.tap()
        
        // Ensure proper dismissal
        XCTAssert(webView.waitForNonExistence(timeout: 10), "Not properly dismissed after purchase.")
    }
    
    // take this out for now -- GitHub actions has lots of issues with it
//    @MainActor
//    func testLoadingStateThenPaywall() throws {
//        let app = makeApp()
//        let trigger = ProcessInfo.processInfo.environment["HELIUM_TRIGGER_KEY"] ?? "ci_annual_monthly"
//        app.launchEnvironment["LOAD_STATE_TEST_TRIGGER"] = trigger
//        app.launch()
//        sleep(2) // Let CI simulator stabilize
//
//        // Paywall loading state should automatically be opened and then show content once paywalls download
//        
//        // Wait for the webview to load
//        let webView = app.webViews.firstMatch
//        XCTAssert(webView.waitForExistence(timeout: 40), "Paywall WebView did not appear")
//        sleep(2) // Buffer for WebView to finish rendering
//
//        let subscribeButton = webView.buttons["START MY FREE TRIAL"].firstMatch
//        XCTAssert(subscribeButton.waitForExistence(timeout: 15), "Subscribe button not found")
//        
//        subscribeButton.tap()
//        
//        let purchaseFeedbackIndicator = app.staticTexts["makePurchaseCalled"]
//        XCTAssert(purchaseFeedbackIndicator.waitForExistence(timeout: 10), "makePurchase method was not called")
//        
//        // Ensure proper dismissal
//        XCTAssert(webView.waitForNonExistence(timeout: 5), "Not properly dismissed after purchase.")
//    }
    
}
