//
//  HeliumExampleUITests.swift
//  HeliumExampleUITests
//
//  Created by Kyle Gorlick on 1/5/26.
//

import XCTest

final class HeliumExampleUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

//    func testAPIKeysAreNotEmpty() {
//        XCTAssertFalse((ProcessInfo.processInfo.environment["HELIUM_API_KEY"] ?? "").isEmpty, "HELIUM_API_KEY should not be empty")
//        XCTAssertFalse((ProcessInfo.processInfo.environment["HELIUM_TRIGGER_KEY"] ?? "").isEmpty, "HELIUM_TRIGGER_KEY should not be empty")
//    }

    @MainActor
    func testPurchase() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UI_TESTING_PURCHASE", "AUTO_FETCH"]
        app.launchEnvironment["LOAD_STATE_TEST_TRIGGER"] = nil
        app.launch()
        
        let triggerButton = app.buttons.matching(identifier: "presentPaywall").firstMatch
        triggerButton.tap()
        
        // Wait for the webview to load
        let webView = app.webViews.firstMatch
        XCTAssert(webView.waitForExistence(timeout: 15), "Paywall WebView did not appear")
        
        // This will match any button containing "claim" or "start" anywhere in the text
        let flexiblePredicate = NSPredicate(format: "label CONTAINS[c] 'claim' OR label CONTAINS[c] 'start' OR label CONTAINS[c] 'subscribe' OR label CONTAINS[c] 'continue'")
        var subscribeButton = webView.buttons.matching(flexiblePredicate).firstMatch
        if !subscribeButton.waitForExistence(timeout: 5) {
            subscribeButton = webView.buttons["btn-subscribe-main"]
            let _ = subscribeButton.waitForExistence(timeout: 5)
        }
        
        XCTAssertTrue(subscribeButton.exists)
        
        subscribeButton.tap()
        
        let purchaseFeedbackIndicator = app.staticTexts["makePurchaseCalled"]
        XCTAssert(purchaseFeedbackIndicator.waitForExistence(timeout: 10), "makePurchase method was not called")
        
        // Ensure proper dismissal
        XCTAssert(webView.waitForNonExistence(timeout: 5), "Not properly dismissed after purchase.")
    }
    
    @MainActor
    func testModifierDisplayAndDismiss() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UI_TESTING_PURCHASE", "AUTO_FETCH"]
        app.launchEnvironment["LOAD_STATE_TEST_TRIGGER"] = nil
        app.launch()
        
        let triggerButton = app.buttons.matching(identifier: "showPaywallViaModifier").firstMatch
        triggerButton.tap()
        
        // Wait for the webview to load
        let webView = app.webViews.firstMatch
        XCTAssert(webView.waitForExistence(timeout: 15), "Paywall WebView did not appear")
        
        // Ensure webview properly displays
        let flexiblePredicate = NSPredicate(format: "label CONTAINS[c] 'claim' OR label CONTAINS[c] 'start' OR label CONTAINS[c] 'subscribe' OR label CONTAINS[c] 'continue'")
        let paywallElement = webView.descendants(matching: .any).matching(flexiblePredicate).firstMatch
        XCTAssert(paywallElement.waitForExistence(timeout: 5), "Paywall content didn't properly display")
        
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
    
    @MainActor
    func testLoadingStateThenPaywall() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UI_TESTING_PURCHASE", "AUTO_FETCH"]
        app.launchEnvironment["LOAD_STATE_TEST_TRIGGER"] = "ci_annual_monthly"
        app.launch()
        
        // Paywall loading state should automatically be opened and then show content once paywalls download
        
        // Wait for the webview to load
        let webView = app.webViews.firstMatch
        XCTAssert(webView.waitForExistence(timeout: 40), "Paywall WebView did not appear")
        
        // This will match any button containing "claim" or "start" anywhere in the text
        let flexiblePredicate = NSPredicate(format: "label CONTAINS[c] 'claim' OR label CONTAINS[c] 'start' OR label CONTAINS[c] 'subscribe' OR label CONTAINS[c] 'continue'")
        var subscribeButton = webView.buttons.matching(flexiblePredicate).firstMatch
        if !subscribeButton.waitForExistence(timeout: 5) {
            subscribeButton = webView.buttons["btn-subscribe-main"]
            let _ = subscribeButton.waitForExistence(timeout: 5)
        }
        
        XCTAssertTrue(subscribeButton.exists)
        
        subscribeButton.tap()
        
        let purchaseFeedbackIndicator = app.staticTexts["makePurchaseCalled"]
        XCTAssert(purchaseFeedbackIndicator.waitForExistence(timeout: 10), "makePurchase method was not called")
        
        // Ensure proper dismissal
        XCTAssert(webView.waitForNonExistence(timeout: 5), "Not properly dismissed after purchase.")
    }
    
}
