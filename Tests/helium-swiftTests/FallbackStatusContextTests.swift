import XCTest
@testable import Helium

final class FallbackStatusContextTests: XCTestCase {

    private let defaultTrigger = HeliumFallbackViewManager.defaultFallbackTrigger

    func testDisclaimerCopy() {
        XCTAssertEqual(FallbackStatusContext.disclaimer, "You're viewing a fallback paywall")
    }

    func testReasonCopyShowsTheRawKeyForEveryReason() {
        for reason in PaywallUnavailableReason.allCases {
            XCTAssertEqual(context(reason: reason).reasonLine, "Reason: \(reason.rawValue)")
        }
    }

    func testRequestedTriggerCopy() {
        XCTAssertEqual(
            context(requestedTrigger: "onboarding_end").requestedTriggerLine,
            "Requested trigger: onboarding_end"
        )
    }

    func testOwnEntryCopy() {
        XCTAssertEqual(
            context(resolvedEntry: .triggerOwnEntry).resolvedEntryLine,
            "Resolved from this trigger's own fallback entry"
        )
    }

    func testDefaultEntryCopyShowsTheRawDefaultKey() {
        XCTAssertEqual(
            context(resolvedTrigger: defaultTrigger, resolvedEntry: .defaultEntry).resolvedEntryLine,
            "Resolved from the default fallback entry (hlm_ios_default_flbk)"
        )
    }

    func testOwnEntryCopyForATriggerNamedLikeTheDefaultKey() {
        // The entry classification comes from the resolution, not the trigger's name, so a trigger
        // that happens to share the default key still reads as its own entry.
        XCTAssertEqual(
            context(resolvedTrigger: defaultTrigger, resolvedEntry: .triggerOwnEntry).resolvedEntryLine,
            "Resolved from this trigger's own fallback entry"
        )
    }

    func testServingPaywallCopy() {
        XCTAssertEqual(
            context(paywallName: "Spring Sale v3").servingPaywallLine,
            "Serving paywall: Spring Sale v3"
        )
    }

    func testServingPaywallCopyWhenTheNameIsUnresolvable() {
        XCTAssertEqual(context(paywallName: nil).servingPaywallLine, "Serving paywall: Unknown paywall")
    }

    func testConfiguredBundleCopyIsSingularForOneTrigger() {
        XCTAssertEqual(
            context(configuredTriggerCount: 1).configuredBundleLine,
            "Fallback bundle configured with 1 trigger"
        )
    }

    func testConfiguredBundleCopyIsPluralForOtherCounts() {
        XCTAssertEqual(
            context(configuredTriggerCount: 3).configuredBundleLine,
            "Fallback bundle configured with 3 triggers"
        )
        XCTAssertEqual(
            context(configuredTriggerCount: 0).configuredBundleLine,
            "Fallback bundle configured with 0 triggers"
        )
    }

    // MARK: - Helpers

    private func context(
        requestedTrigger: String = "onboarding_end",
        reason: PaywallUnavailableReason = .paywallsDownloadFail,
        resolvedTrigger: String = "onboarding_end",
        resolvedEntry: ResolvedFallbackEntry = .triggerOwnEntry,
        paywallName: String? = "Spring Sale v3",
        configuredTriggerCount: Int = 2
    ) -> FallbackStatusContext {
        FallbackStatusContext(
            requestedTrigger: requestedTrigger,
            reason: reason,
            bundleStatus: FallbackBundleStatus(
                resolvedTrigger: resolvedTrigger,
                resolvedEntry: resolvedEntry,
                paywallTemplateName: paywallName,
                configuredTriggerCount: configuredTriggerCount
            )
        )
    }
}
