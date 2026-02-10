import XCTest
@testable import Helium

final class LoadingBudgetTests: XCTestCase {

    private var previousDefaultLoadingBudget: TimeInterval!

    override func setUp() {
        super.setUp()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        previousDefaultLoadingBudget = Helium.config.defaultLoadingBudget
        Helium.config.defaultLoadingBudget = 7.0
    }

    override func tearDown() {
        Helium.config.defaultLoadingBudget = previousDefaultLoadingBudget
        super.tearDown()
    }

    func testDefaultLoadingBudgetUsesConfigDefault() {
        let config = PaywallPresentationConfig()
        XCTAssertTrue(config.useLoadingState)
        XCTAssertEqual(config.safeLoadingBudgetInSeconds, 7.0)
    }

    func testCustomLoadingBudgetOverridesDefault() {
        let config = PaywallPresentationConfig(loadingBudget: 3.0)
        XCTAssertTrue(config.useLoadingState)
        XCTAssertEqual(config.safeLoadingBudgetInSeconds, 3.0)
    }

    func testZeroLoadingBudgetDisablesLoadingState() {
        let config = PaywallPresentationConfig(loadingBudget: 0)
        XCTAssertFalse(config.useLoadingState)
    }

    func testNegativeLoadingBudgetDisablesLoadingState() {
        let config = PaywallPresentationConfig(loadingBudget: -1)
        XCTAssertFalse(config.useLoadingState)
    }

    func testSafeLoadingBudgetClamps() {
        // Max clamp: 100 -> 20
        let highConfig = PaywallPresentationConfig(loadingBudget: 100)
        XCTAssertEqual(highConfig.safeLoadingBudgetInSeconds, 20)

        // Min clamp: 0.1 -> 1
        let lowConfig = PaywallPresentationConfig(loadingBudget: 0.1)
        XCTAssertEqual(lowConfig.safeLoadingBudgetInSeconds, 1)
    }

    func testLoadingBudgetForAnalyticsMS() {
        let config = PaywallPresentationConfig(loadingBudget: 5.0)
        XCTAssertEqual(config.loadingBudgetForAnalyticsMS, 5000)

        let disabledConfig = PaywallPresentationConfig(loadingBudget: 0)
        XCTAssertEqual(disabledConfig.loadingBudgetForAnalyticsMS, 0)
    }
}
