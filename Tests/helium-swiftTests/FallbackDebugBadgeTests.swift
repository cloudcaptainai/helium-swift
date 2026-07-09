import XCTest
@testable import Helium

final class FallbackDebugBadgeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        Helium.resetHelium()
    }

    override func tearDown() {
        Helium.resetHelium()
        super.tearDown()
    }

    func testBadgeHiddenForLiveRemotePaywall() {
        XCTAssertFalse(FallbackDebugBadge.shouldShow(fallbackReason: nil))
    }

    func testBadgeShownForEveryFallbackReason() {
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
                FallbackDebugBadge.shouldShow(fallbackReason: reason),
                "Expected the badge to show for fallback reason \(reason.rawValue)"
            )
        }
    }

    func testResolvedFallbackReasonDrivesTheBadge() {
        Helium.shared.markInitializedForTesting()

        let config = makeTestConfig(triggers: ["other_trigger": makeTestPaywallInfo(trigger: "other_trigger")])
        injectConfig(config)

        let result = HeliumPaywallPresenter.shared.upsellViewResultFor(
            trigger: "nonexistent_trigger",
            presentationContext: PaywallPresentationContext.empty
        )

        XCTAssertEqual(result.fallbackReason, .triggerHasNoPaywall)
        XCTAssertTrue(FallbackDebugBadge.shouldShow(fallbackReason: result.fallbackReason))
    }
}
