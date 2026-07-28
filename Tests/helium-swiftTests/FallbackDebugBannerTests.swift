import XCTest
@testable import Helium

final class FallbackDebugBannerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        Helium.resetHelium()
    }

    override func tearDown() {
        Helium.resetHelium()
        super.tearDown()
    }

    func testBannerHiddenForLiveRemotePaywall() {
        XCTAssertFalse(FallbackDebugBanner.shouldShow(fallbackReason: nil, diagnosticsEnabled: true))
    }

    /// The card's only action is opening the diagnostic modal, so it goes away with it rather than
    /// sitting on the paywall offering details it would refuse to show.
    func testBannerHiddenWhenDiagnosticsAreDisabled() {
        XCTAssertFalse(
            FallbackDebugBanner.shouldShow(fallbackReason: .triggerHasNoPaywall, diagnosticsEnabled: false)
        )
    }

    func testTheGateIsNotConsultedForALiveRemotePaywall() {
        var reads = 0

        _ = FallbackDebugBanner.shouldShow(fallbackReason: nil, diagnosticsEnabled: { reads += 1; return true }())

        XCTAssertEqual(reads, 0)
    }

    func testBannerShownWhenFallbackReasonPresent() {
        let reasons: [PaywallUnavailableReason] = [
            .notInitialized,
            .triggerHasNoPaywall,
            .forceShowFallback,
            .invalidResolvedConfig,
            .paywallsNotDownloaded,
            .paywallsDownloadFail,
            .couldNotFindBundleUrl,
            .noProductsIOS,
            .webCheckoutNoCustomUserId,
            .webCheckoutNotEnabled
        ]

        for reason in reasons {
            XCTAssertTrue(
                FallbackDebugBanner.shouldShow(fallbackReason: reason, diagnosticsEnabled: true),
                "Expected the banner to show for fallback reason \(reason.rawValue)"
            )
        }
    }

    func testResolvedFallbackReasonDrivesTheBanner() {
        Helium.shared.markInitializedForTesting()

        let config = makeTestConfig(triggers: ["other_trigger": makeTestPaywallInfo(trigger: "other_trigger")])
        injectConfig(config)

        let result = HeliumPaywallPresenter.shared.upsellViewResultFor(
            trigger: "nonexistent_trigger",
            presentationContext: PaywallPresentationContext.empty
        )

        XCTAssertEqual(result.fallbackReason, .triggerHasNoPaywall)
        XCTAssertTrue(
            FallbackDebugBanner.shouldShow(fallbackReason: result.fallbackReason, diagnosticsEnabled: true)
        )
    }
}
