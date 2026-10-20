import XCTest

final class SdkApiCoverageUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEveryPublicApiCallIsExercised() throws {
        let app = XCUIApplication()
        app.launchArguments = ["UI_TESTING_PURCHASE", "AUTO_FETCH", "SDK_API_COVERAGE"]
        if let apiKey = ProcessInfo.processInfo.environment["HELIUM_API_KEY"] {
            app.launchEnvironment["HELIUM_API_KEY"] = apiKey
        }
        if let triggerKey = ProcessInfo.processInfo.environment["HELIUM_TRIGGER_KEY"] {
            app.launchEnvironment["HELIUM_TRIGGER_KEY"] = triggerKey
        }
        app.launch()

        let status = app.staticTexts["sdkApiCoverageStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let done = NSPredicate(format: "label == %@", "coverage done")
        let finished = expectation(for: done, evaluatedWith: status)
        wait(for: [finished], timeout: 120)

        app.buttons["showPaywallViaModifier"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
        sleep(3)
        app.terminate()
        app.launch()

        app.buttons["showPaywallEmbedded"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
        sleep(3)
    }
}
