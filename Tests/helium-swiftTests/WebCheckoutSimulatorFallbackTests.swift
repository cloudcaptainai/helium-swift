import XCTest
@testable import Helium

final class WebCheckoutSimulatorFallbackTests: XCTestCase {

    private let trigger = "web_trigger"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(HeliumRuntimeEnvironment.isSimulator)
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        Helium.resetHelium()
        Helium.shared.markInitializedForTesting()
        Helium.config.enableExternalWebCheckout(
            redirectURL: "myapp://checkout/return",
            paymentProcessors: .all
        )
        Helium.config.allowWebCheckoutWithoutUserId = true
    }

    override func tearDown() {
        Helium.config.disableExternalWebCheckout()
        Helium.config.allowWebCheckoutWithoutUserId = false
        Helium.resetHelium()
        super.tearDown()
    }

    func testStripePaywallFallsBackOnSimulator() {
        injectPaywall { $0.productsOfferedStripe = ["stripe_product:price_1"] }

        XCTAssertEqual(fallbackReason(for: trigger), .webCheckoutUnsupportedOnSimulator)
    }

    func testPaddlePaywallFallsBackOnSimulator() {
        injectPaywall { $0.productsOfferedPaddle = ["paddle_product:pri_1"] }

        XCTAssertEqual(fallbackReason(for: trigger), .webCheckoutUnsupportedOnSimulator)
    }

    func testWebPaywallProductsFallBackOnSimulator() {
        injectPaywall { $0.webProductsOfferedStripe = ["stripe_product:price_1"] }

        XCTAssertEqual(fallbackReason(for: trigger), .webCheckoutUnsupportedOnSimulator)
    }

    func testPaywallWithoutWebProductsIsUnaffected() {
        injectPaywall { _ in }

        XCTAssertNotEqual(fallbackReason(for: trigger), .webCheckoutUnsupportedOnSimulator)
    }

    func testMissingUserIdIsReportedBeforeTheSimulator() {
        Helium.config.allowWebCheckoutWithoutUserId = false
        injectPaywall { $0.productsOfferedStripe = ["stripe_product:price_1"] }

        XCTAssertEqual(fallbackReason(for: trigger), .webCheckoutNoCustomUserId)
    }

    func testDisabledProcessorIsReportedBeforeTheSimulator() {
        Helium.config.disableExternalWebCheckout()
        injectPaywall { $0.productsOfferedStripe = ["stripe_product:price_1"] }

        XCTAssertEqual(fallbackReason(for: trigger), .webCheckoutNotEnabled)
    }

    func testPreviewTriggerIsExempt() throws {
        let config = makeTestConfig(triggers: ["a_trigger": makeTestPaywallInfo()])
        injectConfig(config, json: try JSON(data: JSONEncoder().encode(config)))
        try HeliumFetchedConfigManager.shared.setPreviewTriggerConfig(
            bundleId: "preview456",
            bundleUrl: "https://cdn.example.com/bundles/bundle_preview456.html",
            bundleHtml: "<html>preview</html>",
            productIds: ["preview.product"],
            productIdsStripe: ["stripe_product:price_1"],
            productIdsPaddle: [],
            productIdsPaddleWeb: [],
            productIdsStripeWeb: []
        )

        XCTAssertNotEqual(
            fallbackReason(for: HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER),
            .webCheckoutUnsupportedOnSimulator
        )
    }

    private func injectPaywall(_ configure: (inout HeliumPaywallInfo) -> Void) {
        var paywallInfo = makeTestPaywallInfo(trigger: trigger)
        configure(&paywallInfo)
        injectConfig(makeTestConfig(triggers: [trigger: paywallInfo]))
    }

    private func fallbackReason(for trigger: String) -> PaywallUnavailableReason? {
        HeliumPaywallPresenter.shared.upsellViewResultFor(
            trigger: trigger,
            presentationContext: PaywallPresentationContext.empty
        ).fallbackReason
    }
}
