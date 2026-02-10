import XCTest
@testable import Helium

final class FallbackScenarioTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        Helium.resetHelium()
    }

    override func tearDown() {
        Helium.resetHelium()
        super.tearDown()
    }

    func testNotInitializedReturnsFallbackReason() {
        // Don't initialize
        let result = Helium.shared.upsellViewResultFor(
            trigger: "test",
            presentationContext: PaywallPresentationContext.empty
        )
        XCTAssertNil(result.viewAndSession)
        XCTAssertEqual(result.fallbackReason, .notInitialized)
    }

    func testTriggerHasNoPaywallReturnsFallbackReason() {
        Helium.shared.markInitializedForTesting()

        // Inject config with a DIFFERENT trigger
        let config = makeTestConfig(triggers: ["other_trigger": makeTestPaywallInfo(trigger: "other_trigger")])
        injectConfig(config)

        let result = Helium.shared.upsellViewResultFor(
            trigger: "nonexistent_trigger",
            presentationContext: PaywallPresentationContext.empty
        )
        XCTAssertEqual(result.fallbackReason, .triggerHasNoPaywall)
    }

    func testNoProductsIOSReturnsFallbackReason() {
        Helium.shared.markInitializedForTesting()

        let paywallInfo = makeTestPaywallInfo(trigger: "no_products", products: [])
        let config = makeTestConfig(triggers: ["no_products": paywallInfo])
        injectConfig(config)

        let result = Helium.shared.upsellViewResultFor(
            trigger: "no_products",
            presentationContext: PaywallPresentationContext.empty
        )
        XCTAssertEqual(result.fallbackReason, .noProductsIOS)
    }

    func testForceShowFallbackReturnsFallbackReason() {
        Helium.shared.markInitializedForTesting()

        let paywallInfo = makeTestPaywallInfo(trigger: "force_fallback", forceShowFallback: true)
        let config = makeTestConfig(triggers: ["force_fallback": paywallInfo])
        injectConfig(config)

        let result = Helium.shared.upsellViewResultFor(
            trigger: "force_fallback",
            presentationContext: PaywallPresentationContext.empty
        )
        XCTAssertEqual(result.fallbackReason, .forceShowFallback)
    }

    func testDownloadNotCompletedReturnsFallbackReason() {
        Helium.shared.markInitializedForTesting()

        // Don't inject any config - download status stays at notDownloadedYet
        let result = Helium.shared.upsellViewResultFor(
            trigger: "test",
            presentationContext: PaywallPresentationContext.empty
        )
        XCTAssertNil(result.viewAndSession)
        // After reset with no config injected, download status is .notDownloadedYet
        XCTAssertEqual(result.fallbackReason, .paywallsNotDownloaded)
    }
}
