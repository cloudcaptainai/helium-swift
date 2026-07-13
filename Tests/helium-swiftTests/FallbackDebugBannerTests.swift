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

    func testBannerShownForEveryFallbackReason() {
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

    /// This copy reaches developers verbatim, in the diagnostic view's body and in the log line, so
    /// a rewrite here changes what they are told. Pin it.
    func testRemediationCopyIsAuthoredNotDerived() {
        XCTAssertEqual(
            PaywallDiagnosticMessages.remediationMessage(for: .notInitialized, trigger: "t"),
            "Helium is not initialized"
        )
        XCTAssertEqual(
            PaywallDiagnosticMessages.remediationMessage(for: .paywallsDownloadFail, trigger: "t"),
            "Paywalls failed to download. Check your connection and Helium API key"
        )
        XCTAssertEqual(
            PaywallDiagnosticMessages.remediationMessage(for: .webCheckoutNoCustomUserId, trigger: "t"),
            "External Web Checkout requires a custom user ID to be set"
        )
    }

    func testRemediationCopyInterpolatesTheTrigger() {
        let message = PaywallDiagnosticMessages.remediationMessage(
            for: .triggerHasNoPaywall,
            trigger: "onboarding_end"
        )

        XCTAssertTrue(message.contains("\"onboarding_end\""))
        XCTAssertTrue(message.contains("https://app.tryhelium.com/workflows"))
    }

    /// A tapped banner must reach the diagnostic view with real remediation copy, never a bare
    /// enum case leaking into the modal body.
    func testEveryFallbackReasonYieldsRemediationCopyRatherThanARawCode() {
        let reasons: [PaywallUnavailableReason] = [
            .notInitialized,
            .triggerHasNoPaywall,
            .paywallsNotDownloaded,
            .paywallsDownloadFail,
            .couldNotFindBundleUrl,
            .noProductsIOS,
            .webCheckoutNoCustomUserId,
            .webCheckoutNotEnabled
        ]

        for reason in reasons {
            let message = PaywallDiagnosticMessages.remediationMessage(for: reason, trigger: "t")
            XCTAssertFalse(message.isEmpty, "no copy for \(reason.rawValue)")
            XCTAssertNotEqual(
                message,
                reason.rawValue,
                "\(reason.rawValue) leaks its raw code into the diagnostic body"
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
