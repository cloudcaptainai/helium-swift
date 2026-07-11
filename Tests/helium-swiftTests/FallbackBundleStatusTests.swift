import XCTest
@testable import Helium

final class FallbackBundleStatusTests: XCTestCase {

    private let defaultTrigger = HeliumFallbackViewManager.defaultFallbackTrigger

    override func setUp() {
        super.setUp()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        Helium.resetHelium()
    }

    override func tearDown() {
        Helium.resetHelium()
        super.tearDown()
    }

    func testResolutionIsNilWhenNoBundleIsLoaded() {
        XCTAssertNil(HeliumFallbackViewManager.shared.resolveFallback(for: "onboarding_end"))
    }

    func testTriggerWithItsOwnUsableEntryResolvesToThatEntry() {
        loadFallbackBundle(triggers: ["onboarding_end", defaultTrigger])

        let resolved = HeliumFallbackViewManager.shared.resolveFallback(for: "onboarding_end")

        XCTAssertEqual(resolved?.status.resolvedTrigger, "onboarding_end")
        XCTAssertEqual(resolved?.status.resolvedEntry, .triggerOwnEntry)
    }

    func testTriggerWithoutItsOwnEntryResolvesToTheDefaultEntry() {
        loadFallbackBundle(triggers: [defaultTrigger])

        let resolved = HeliumFallbackViewManager.shared.resolveFallback(for: "onboarding_end")

        XCTAssertEqual(resolved?.status.resolvedTrigger, defaultTrigger)
        XCTAssertEqual(resolved?.status.resolvedEntry, .defaultEntry)
    }

    func testTriggerWhoseEntryHasNoProductsResolvesToTheDefaultEntry() {
        loadFallbackBundle(
            triggers: ["onboarding_end", defaultTrigger],
            triggersWithoutProducts: ["onboarding_end"]
        )

        let resolved = HeliumFallbackViewManager.shared.resolveFallback(for: "onboarding_end")

        XCTAssertEqual(resolved?.status.resolvedTrigger, defaultTrigger)
        XCTAssertEqual(resolved?.status.resolvedEntry, .defaultEntry)
    }

    func testTriggerWhoseEntryLacksAResolvedConfigResolvesToTheDefaultEntry() {
        loadFallbackBundle(
            triggers: ["onboarding_end", defaultTrigger],
            triggersWithoutResolvedConfig: ["onboarding_end"]
        )

        let resolved = HeliumFallbackViewManager.shared.resolveFallback(for: "onboarding_end")

        XCTAssertEqual(resolved?.status.resolvedTrigger, defaultTrigger)
        XCTAssertEqual(resolved?.status.resolvedEntry, .defaultEntry)
    }

    func testTriggerNamedLikeTheDefaultKeyWithAUsableEntryResolvesAsItsOwnEntry() {
        loadFallbackBundle(triggers: [defaultTrigger])

        let resolved = HeliumFallbackViewManager.shared.resolveFallback(for: defaultTrigger)

        XCTAssertEqual(resolved?.status.resolvedTrigger, defaultTrigger)
        XCTAssertEqual(resolved?.status.resolvedEntry, .triggerOwnEntry)
    }

    func testTemplateNameIsPassedThroughFromTheResolvedEntry() {
        loadFallbackBundle(triggers: ["onboarding_end"], paywallNames: ["onboarding_end": "Spring Sale v3"])

        let resolved = HeliumFallbackViewManager.shared.resolveFallback(for: "onboarding_end")

        XCTAssertEqual(resolved?.status.paywallTemplateName, "Spring Sale v3")
    }

    func testTemplateNameAndPaywallInfoAreNilWhenTheResolvedEntryIsAbsentFromTheBundle() {
        // A bundle with no default entry: an unmapped trigger resolves to a key that is not there.
        loadFallbackBundle(triggers: ["some_other_trigger"])

        let resolved = HeliumFallbackViewManager.shared.resolveFallback(for: "onboarding_end")

        XCTAssertEqual(resolved?.status.resolvedTrigger, defaultTrigger)
        XCTAssertNil(resolved?.status.paywallTemplateName)
        XCTAssertNil(resolved?.paywallInfo)
    }

    func testPaywallInfoAndStatusDescribeTheSameEntry() {
        loadFallbackBundle(triggers: ["onboarding_end"], paywallNames: ["onboarding_end": "Spring Sale v3"])

        let resolved = HeliumFallbackViewManager.shared.resolveFallback(for: "onboarding_end")

        XCTAssertEqual(resolved?.paywallInfo?.paywallTemplateName, resolved?.status.paywallTemplateName)
    }

    func testConfiguredTriggerCountExcludesTheDefaultEntry() {
        loadFallbackBundle(triggers: ["onboarding_end", "paywall_open", defaultTrigger])

        let resolved = HeliumFallbackViewManager.shared.resolveFallback(for: "onboarding_end")

        XCTAssertEqual(resolved?.status.configuredTriggerCount, 2)
    }
}
