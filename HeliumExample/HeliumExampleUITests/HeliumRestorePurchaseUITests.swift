//
//  HeliumRestorePurchaseUITests.swift
//  HeliumExampleUITests
//

import XCTest

final class HeliumRestorePurchaseUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Creates a configured XCUIApplication with env vars passed from CI
    private func makeApp(restoreSuccess: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UI_TESTING_PURCHASE", "AUTO_FETCH"]
        app.launchArguments.append(restoreSuccess ? "UI_TESTING_RESTORE_SUCCESS" : "UI_TESTING_RESTORE_FAIL")

        if let apiKey = ProcessInfo.processInfo.environment["HELIUM_API_KEY"] {
            app.launchEnvironment["HELIUM_API_KEY"] = apiKey
        }
        if let triggerKey = ProcessInfo.processInfo.environment["HELIUM_TRIGGER_KEY"] {
            app.launchEnvironment["HELIUM_TRIGGER_KEY"] = triggerKey
        }

        return app
    }

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

        let restoreButton = webView.buttons["Restore Purchases"].firstMatch
        guard restoreButton.waitForExistence(timeout: 10) else {
            throw XCTSkip("Restore Purchases button not found in this paywall configuration")
        }
        restoreButton.tap()

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

        XCTAssert(webView.waitForNonExistence(timeout: 10), "Paywall did not dismiss after successful restore")
    }

}
