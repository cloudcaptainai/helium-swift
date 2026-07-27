import XCTest
@testable import Helium

/// Covers the common enrichment the observability manager attaches to every event.
///
/// Assertions deliberately cover only the paywall-scope keys and static platform
/// context. Identity values depend on device/session state and are not pinned here.
final class HeliumObservabilityManagerTests: XCTestCase {

    func testEnrichWithoutScopeOmitsPaywallScopeKeys() {
        let enriched = HeliumObservabilityManager.shared.enrich(eventProps: [:], scope: nil)

        XCTAssertNil(enriched["heliumPaywallSessionId"])
        XCTAssertNil(enriched["triggerName"])
        XCTAssertNil(enriched["paywallUUID"])
        XCTAssertEqual(enriched["platform"] as? String, "ios")
    }

    func testEnrichWithScopeIncludesPaywallScopeKeys() {
        let scope = PaywallObservabilityScope(
            sessionId: "session_1",
            trigger: "onboarding",
            paywallUUID: "uuid_1"
        )

        let enriched = HeliumObservabilityManager.shared.enrich(eventProps: [:], scope: scope)

        XCTAssertEqual(enriched["heliumPaywallSessionId"] as? String, "session_1")
        XCTAssertEqual(enriched["triggerName"] as? String, "onboarding")
        XCTAssertEqual(enriched["paywallUUID"] as? String, "uuid_1")
    }

    func testEnrichWithScopeMissingAPaywallUUIDOmitsOnlyThatKey() {
        let scope = PaywallObservabilityScope(
            sessionId: "session_1",
            trigger: "onboarding",
            paywallUUID: nil
        )

        let enriched = HeliumObservabilityManager.shared.enrich(eventProps: [:], scope: scope)

        XCTAssertNil(enriched["paywallUUID"])
        XCTAssertEqual(enriched["heliumPaywallSessionId"] as? String, "session_1")
        XCTAssertEqual(enriched["triggerName"] as? String, "onboarding")
    }

    func testEnrichPreservesEventProperties() {
        let enriched = HeliumObservabilityManager.shared.enrich(
            eventProps: ["triggerCount": 2],
            scope: nil
        )

        XCTAssertEqual(enriched["triggerCount"] as? Int, 2)
    }
}
