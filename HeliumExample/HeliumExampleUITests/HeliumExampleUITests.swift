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
        
        // This will match any button containing "claim" or "start" anywhere in the text
        let flexiblePredicate = NSPredicate(format: "label CONTAINS[c] 'claim' OR label CONTAINS[c] 'start' OR label CONTAINS[c] 'subscribe' OR label CONTAINS[c] 'continue'")
        var subscribeButton = webView.buttons.matching(flexiblePredicate).firstMatch
        if !subscribeButton.waitForExistence(timeout: 10) {
            subscribeButton = webView.descendants(matching: .any).matching(flexiblePredicate).firstMatch
            let _ = subscribeButton.waitForExistence(timeout: 10)
        }
        
        XCTAssertTrue(subscribeButton.exists, "No subscribe/purchase button found.")
        
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
        let flexiblePredicate = NSPredicate(format: "label CONTAINS[c] 'claim' OR label CONTAINS[c] 'start' OR label CONTAINS[c] 'subscribe' OR label CONTAINS[c] 'continue'")
        var subscribeButton = webView.buttons.matching(flexiblePredicate).firstMatch
        if !subscribeButton.waitForExistence(timeout: 10) {
            subscribeButton = webView.descendants(matching: .any).matching(flexiblePredicate).firstMatch
            let _ = subscribeButton.waitForExistence(timeout: 10)
        }
        
        XCTAssertTrue(subscribeButton.exists, "No subscribe/purchase button found.")
        
        // Try to close the paywall
        // First attempt: tap top-left where close button might be
        let topLeftClose = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.08))
        topLeftClose.tap()
        
        //then top-right
        let topRightClose = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.08))
        topRightClose.tap()

        // Check if webview was dismissed
        if !webView.waitForNonExistence(timeout: 2) {
            // If still visible, look for a dismissal button with text
            let dismissPredicate = NSPredicate(format: "label CONTAINS[c] 'no thank' OR label CONTAINS[c] 'cancel' OR label CONTAINS[c] 'no, thank' OR label CONTAINS[c] 'close' OR label CONTAINS[c] 'dismiss' OR label CONTAINS[c] 'later'")
            let dismissButton = webView.descendants(matching: .any).matching(dismissPredicate).firstMatch
            
            if dismissButton.waitForExistence(timeout: 3) {
                dismissButton.tap()
            } else {
                // If no button found, try tapping top-left again as fallback
                topLeftClose.tap()
            }
        }
        
        // Ensure proper dismissal
        XCTAssert(webView.waitForNonExistence(timeout: 5), "Not properly dismissed after purchase.")
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
//        // This will match any button containing "claim" or "start" anywhere in the text
//        let flexiblePredicate = NSPredicate(format: "label CONTAINS[c] 'claim' OR label CONTAINS[c] 'start' OR label CONTAINS[c] 'subscribe' OR label CONTAINS[c] 'continue'")
//        var subscribeButton = webView.buttons.matching(flexiblePredicate).firstMatch
//        if !subscribeButton.waitForExistence(timeout: 5) {
//            subscribeButton = webView.buttons["btn-subscribe-main"]
//            let _ = subscribeButton.waitForExistence(timeout: 5)
//        }
//        
//        XCTAssertTrue(subscribeButton.exists)
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
