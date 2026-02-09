import XCTest
@testable import Helium

final class FallbackScenarioTests: XCTestCase {

    override func setUp() {
        super.setUp()
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
        // Initialize Helium (mark as initialized)
        Helium.shared.initialize(apiKey: "test_key_for_unit_test")

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
        Helium.shared.initialize(apiKey: "test_key_for_unit_test")

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
        Helium.shared.initialize(apiKey: "test_key_for_unit_test")

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
        Helium.shared.initialize(apiKey: "test_key_for_unit_test")

        // Don't inject any config - download status stays at its current state
        // After initialize without network, it will be inProgress or notDownloadedYet
        let result = Helium.shared.upsellViewResultFor(
            trigger: "test",
            presentationContext: PaywallPresentationContext.empty
        )
        XCTAssertNil(result.viewAndSession)
        // Should be one of the download-related reasons
        let validReasons: [PaywallUnavailableReason] = [
            .paywallsNotDownloaded, .configFetchInProgress, .bundlesFetchInProgress,
            .productsFetchInProgress, .paywallsDownloadFail, .paywallBundlesMissing
        ]
        XCTAssertTrue(validReasons.contains(result.fallbackReason!),
                       "Expected download-related fallback reason, got: \(result.fallbackReason!)")
    }
}
