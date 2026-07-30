import XCTest
@testable import Helium

/// Tests for previewing the bundled default fallback paywall from the control panel:
/// `setFallbackPreviewTrigger` arms the preview trigger to render the fallback, independent
/// of any fetched config.
final class FallbackPreviewTests: XCTestCase {

    private let previewTrigger = HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER
    private let fallbackBundleUrl = "https://cdn.example.com/bundles/bundle_flbk123.html"

    override func setUp() {
        super.setUp()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        Helium.resetHelium()
    }

    override func tearDown() {
        Helium.resetHelium()
        super.tearDown()
    }

    private func makeFallbackEntry() -> HeliumPaywallInfo {
        var info = makeTestPaywallInfo(paywallName: "default_fallback_paywall", products: ["fallback.product"])
        info.resolvedConfig = AnyCodable([
            "baseStack": [
                "componentProps": [
                    "bundleURL": fallbackBundleUrl
                ]
            ]
        ] as [String: Any])
        return info
    }

    /// Loads a renderable default fallback entry into the fallback manager, including the JSON
    /// mirror that resolution and rendering read for `resolvedConfig`.
    @discardableResult
    private func injectFallbackConfig() throws -> HeliumPaywallInfo {
        let entry = makeFallbackEntry()
        let config = makeTestConfig(
            triggers: [HeliumFallbackViewManager.defaultFallbackTrigger: entry],
            bundles: ["flbk123": "<html>fallback</html>"]
        )
        let json = try JSON(data: JSONEncoder().encode(config))
        HeliumFallbackViewManager.shared.injectFallbackConfigForTesting(config, json: json)
        return entry
    }

    private func installDashboardPreview() throws {
        var donor = makeTestPaywallInfo(paywallName: "donor_paywall", products: ["donor.product"])
        donor.resolvedConfig = AnyCodable([
            "baseStack": [
                "componentProps": [
                    "bundleURL": "https://cdn.example.com/bundles/bundle_donor123.html"
                ]
            ]
        ] as [String: Any])
        injectConfig(makeTestConfig(triggers: ["a_trigger": donor]))

        try HeliumFetchedConfigManager.shared.setPreviewTriggerConfig(
            bundleId: "preview456",
            bundleUrl: "https://cdn.example.com/bundles/bundle_preview456.html",
            bundleHtml: "<html>preview</html>",
            productIds: ["preview.product"],
            productIdsStripe: [],
            productIdsPaddle: [],
            productIdsPaddleWeb: [],
            productIdsStripeWeb: []
        )
    }

    private func upsellResult(trigger: String) -> PaywallViewResult {
        HeliumPaywallPresenter.shared.upsellViewResultFor(
            trigger: trigger,
            presentationContext: PaywallPresentationContext.empty
        )
    }

    // MARK: - Arming

    func testSetFallbackPreviewTriggerArmsWhenFallbackConfigured() throws {
        try injectFallbackConfig()

        XCTAssertTrue(HeliumFetchedConfigManager.shared.hasConfiguredFallbackPreview())
        XCTAssertTrue(HeliumFetchedConfigManager.shared.setFallbackPreviewTrigger())
        XCTAssertTrue(HeliumFetchedConfigManager.shared.isFallbackPreviewArmed)
    }

    func testSetFallbackPreviewTriggerReturnsFalseWithNoFallbackLoaded() {
        XCTAssertFalse(HeliumFetchedConfigManager.shared.hasConfiguredFallbackPreview())
        XCTAssertFalse(HeliumFetchedConfigManager.shared.setFallbackPreviewTrigger())
        XCTAssertFalse(HeliumFetchedConfigManager.shared.isFallbackPreviewArmed)
    }

    // MARK: - Resolution

    /// The core offline guarantee: an armed fallback preview renders with no fetched config at
    /// all, serving the default fallback entry's own bundle under the preview trigger.
    func testFallbackPreviewRendersWithNilFetchedConfig() throws {
        Helium.shared.markInitializedForTesting()
        let entry = try injectFallbackConfig()
        XCTAssertTrue(HeliumFetchedConfigManager.shared.setFallbackPreviewTrigger())
        XCTAssertNil(HeliumFetchedConfigManager.shared.fetchedConfig)

        let result = upsellResult(trigger: previewTrigger)

        XCTAssertNotNil(result.viewAndSession)
        XCTAssertEqual(result.fallbackReason, .forceShowFallback)
        let session = result.viewAndSession?.paywallSession
        XCTAssertEqual(session?.trigger, previewTrigger)
        XCTAssertEqual(session?.fallbackType, .fallbackBundle)
        XCTAssertEqual(session?.paywallInfoWithBackups?.paywallTemplateName, entry.paywallTemplateName)
    }

    func testUnarmedPreviewTriggerNeverRendersTheFallback() throws {
        Helium.shared.markInitializedForTesting()
        try injectFallbackConfig()

        let result = upsellResult(trigger: previewTrigger)

        XCTAssertNil(result.viewAndSession)
        XCTAssertEqual(result.fallbackReason, .paywallsNotDownloaded)
    }

    /// A real trigger served by the fallback keeps its own unavailable reason; only the armed
    /// preview is labeled forceShowFallback.
    func testRealTriggerFallbackIsNotLabeledForceShowFallback() throws {
        Helium.shared.markInitializedForTesting()
        try injectFallbackConfig()

        let result = upsellResult(trigger: "real_trigger")

        XCTAssertNotNil(result.viewAndSession)
        XCTAssertEqual(result.fallbackReason, .paywallsNotDownloaded)
        XCTAssertEqual(result.viewAndSession?.paywallSession.fallbackType, .fallbackBundle)
    }

    /// The webview's injected context and price map resolve products by trigger name, and no
    /// fetched-config entry exists under the preview trigger while armed, so the lookup must
    /// serve the fallback entry's own products.
    func testArmedPreviewServesFallbackProductContext() throws {
        try injectFallbackConfig()
        XCTAssertTrue(HeliumFetchedConfigManager.shared.setFallbackPreviewTrigger())

        XCTAssertEqual(
            HeliumFetchedConfigManager.shared.getProductIDsForTrigger(previewTrigger),
            ["fallback.product"]
        )
        let context = createHeliumContext(triggerName: previewTrigger)
        XCTAssertEqual(
            context["products"]["productIds"].arrayValue.map(\.stringValue),
            ["fallback.product"]
        )
    }

    // MARK: - Mutual exclusion with dashboard previews

    func testDashboardPreviewDisarmsFallbackPreview() throws {
        try injectFallbackConfig()
        XCTAssertTrue(HeliumFetchedConfigManager.shared.setFallbackPreviewTrigger())

        try installDashboardPreview()

        XCTAssertFalse(HeliumFetchedConfigManager.shared.isFallbackPreviewArmed)
        XCTAssertEqual(
            HeliumFetchedConfigManager.shared.getProductIDsForTrigger(previewTrigger),
            ["preview.product"]
        )
    }

    func testFallbackPreviewArmWinsOverEarlierDashboardPreview() throws {
        Helium.shared.markInitializedForTesting()
        try injectFallbackConfig()
        try installDashboardPreview()
        XCTAssertNotNil(HeliumFetchedConfigManager.shared.fetchedConfig?.triggerToPaywalls[previewTrigger])

        XCTAssertTrue(HeliumFetchedConfigManager.shared.setFallbackPreviewTrigger())

        XCTAssertNil(HeliumFetchedConfigManager.shared.fetchedConfig?.triggerToPaywalls[previewTrigger])
        XCTAssertEqual(
            HeliumFetchedConfigManager.shared.getProductIDsForTrigger(previewTrigger),
            ["fallback.product"]
        )
        let result = upsellResult(trigger: previewTrigger)
        XCTAssertEqual(result.fallbackReason, .forceShowFallback)
        XCTAssertEqual(result.viewAndSession?.paywallSession.fallbackType, .fallbackBundle)
    }

    func testResetClearsFallbackPreviewArm() throws {
        try injectFallbackConfig()
        XCTAssertTrue(HeliumFetchedConfigManager.shared.setFallbackPreviewTrigger())

        HeliumFetchedConfigManager.reset()

        XCTAssertFalse(HeliumFetchedConfigManager.shared.isFallbackPreviewArmed)
    }

    // MARK: - Wire format parity with Android

    func testForceShowFallbackWireFormat() {
        XCTAssertEqual(PaywallUnavailableReason.forceShowFallback.rawValue, "forceShowFallback")

        let event = PaywallOpenEvent(
            triggerName: previewTrigger,
            paywallName: "default_fallback_paywall",
            viewType: .presented,
            paywallUnavailableReason: .forceShowFallback
        )
        XCTAssertEqual(event.toDictionary()["paywallUnavailableReason"] as? String, "forceShowFallback")
    }
}
