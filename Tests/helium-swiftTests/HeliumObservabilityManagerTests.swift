import XCTest
@testable import Helium

/// Covers the common enrichment the observability manager attaches to every event.
///
/// Assertions deliberately cover only the paywall-scope keys and static platform
/// context. Identity values depend on device/session state and are not pinned here.
final class HeliumObservabilityManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Enrichment reads the organization off the downloaded config; clear it so
        // the no-downloaded-config path is what's under test.
        HeliumFetchedConfigManager.reset()
    }

    override func tearDown() {
        HeliumIdentityManager.shared.setThirdPartyAnalyticsAnonymousId(nil)
        super.tearDown()
    }

    /// Events that carry their own organization must keep it when no downloaded
    /// config is available, otherwise early-startup telemetry loses its org.
    func testEnrichKeepsAnEventSuppliedOrganizationWhenNoConfigIsDownloaded() {
        let enriched = HeliumObservabilityManager.shared.enrich(
            eventProps: ["organizationId": "org-from-bundle"],
            scope: nil
        )

        XCTAssertEqual(enriched["organizationId"] as? String, "org-from-bundle")
    }

    func testEnrichWithoutScopeOmitsPaywallScopeKeys() {
        let enriched = HeliumObservabilityManager.shared.enrich(eventProps: [:], scope: nil)

        XCTAssertNil(enriched["heliumPaywallSessionId"])
        XCTAssertNil(enriched["triggerName"])
        XCTAssertNil(enriched["paywallUUID"])
        XCTAssertNil(enriched["isFallback"])
        XCTAssertEqual(enriched["platform"] as? String, "ios")
    }

    func testEnrichWithScopeIncludesPaywallScopeKeys() {
        let scope = PaywallObservabilityScope(
            sessionId: "session_1",
            trigger: "onboarding",
            paywallUUID: "uuid_1",
            isFallback: false
        )

        let enriched = HeliumObservabilityManager.shared.enrich(eventProps: [:], scope: scope)

        XCTAssertEqual(enriched["heliumPaywallSessionId"] as? String, "session_1")
        XCTAssertEqual(enriched["triggerName"] as? String, "onboarding")
        XCTAssertEqual(enriched["paywallUUID"] as? String, "uuid_1")
        XCTAssertEqual(enriched["isFallback"] as? Bool, false)
    }

    func testEnrichWithFallbackScopeMarksTheEventAsFallback() {
        let scope = PaywallObservabilityScope(
            sessionId: "session_1",
            trigger: "onboarding",
            paywallUUID: nil,
            isFallback: true
        )

        let enriched = HeliumObservabilityManager.shared.enrich(eventProps: [:], scope: scope)

        XCTAssertEqual(enriched["isFallback"] as? Bool, true)
    }

    func testEnrichWithScopeMissingAPaywallUUIDOmitsOnlyThatKey() {
        let scope = PaywallObservabilityScope(
            sessionId: "session_1",
            trigger: "onboarding",
            paywallUUID: nil,
            isFallback: false
        )

        let enriched = HeliumObservabilityManager.shared.enrich(eventProps: [:], scope: scope)

        XCTAssertNil(enriched["paywallUUID"])
        XCTAssertEqual(enriched["heliumPaywallSessionId"] as? String, "session_1")
        XCTAssertEqual(enriched["triggerName"] as? String, "onboarding")
    }

    func testEnrichWithoutWrapperSdkFallsBackToNativeVersionAndPlatform() {
        let enriched = HeliumObservabilityManager.shared.enrich(eventProps: [:], scope: nil)

        XCTAssertEqual(enriched["sdkVersionWrapper"] as? String, BuildConstants.version)
        XCTAssertEqual(enriched["wrapperSdk"] as? String, "ios")
    }

    func testEnrichIncludesThirdPartyAnalyticsAnonymousIdWhenSet() {
        HeliumIdentityManager.shared.setThirdPartyAnalyticsAnonymousId("third_party_anon_1")

        let enriched = HeliumObservabilityManager.shared.enrich(eventProps: [:], scope: nil)

        XCTAssertEqual(enriched["thirdPartyAnalyticsAnonymousId"] as? String, "third_party_anon_1")
    }

    func testEnrichOmitsThirdPartyAnalyticsAnonymousIdWhenUnset() {
        HeliumIdentityManager.shared.setThirdPartyAnalyticsAnonymousId(nil)

        let enriched = HeliumObservabilityManager.shared.enrich(eventProps: [:], scope: nil)

        XCTAssertNil(enriched["thirdPartyAnalyticsAnonymousId"])
    }

    func testEnrichPreservesEventProperties() {
        let enriched = HeliumObservabilityManager.shared.enrich(
            eventProps: ["triggerCount": 2],
            scope: nil
        )

        XCTAssertEqual(enriched["triggerCount"] as? Int, 2)
    }
}
