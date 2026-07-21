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
        XCTAssertFalse(FallbackDebugBanner.shouldShow(fallbackReason: nil))
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
                FallbackDebugBanner.shouldShow(fallbackReason: reason),
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
        XCTAssertTrue(FallbackDebugBanner.shouldShow(fallbackReason: result.fallbackReason))
    }
}
