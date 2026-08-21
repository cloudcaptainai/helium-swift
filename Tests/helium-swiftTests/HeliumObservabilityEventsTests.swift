import XCTest
@testable import Helium

/// Locks down the observability wire format for per-event payloads, before the
/// manager attaches identity, scope, and platform enrichment.
///
/// These names and keys must stay aligned with the Android SDK so both platforms
/// land in the same dashboards. Do not change the expectations without also
/// changing Android.
final class HeliumObservabilityEventsTests: XCTestCase {

    // MARK: - Helpers

    /// Payload round-tripped through SegmentJSON + JSONEncoder, i.e. exactly what
    /// goes on the wire.
    private func wireProperties(for event: any HeliumObservabilityEvent) throws -> NSDictionary {
        let json = try SegmentJSON(event.properties)
        let data = try JSONEncoder().encode(json)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    // MARK: - PaywallLinkOpenAttempted

    func testPaywallLinkOpenCarriesSourceDestinationSuccessSchemeAndUrl() throws {
        let event = PaywallLinkOpenAttempted(
            source: .navigate,
            openedInApp: true,
            success: true,
            scheme: "https",
            url: "https://tryhelium.com/pricing"
        )

        XCTAssertEqual(event.name, "paywall_link_open_attempted")
        XCTAssertEqual(try wireProperties(for: event), NSDictionary(dictionary: [
            "source": "navigate",
            "openedInApp": true,
            "success": true,
            "scheme": "https",
            "url": "https://tryhelium.com/pricing",
        ]))
    }

    func testPaywallLinkOpenWithoutASchemeOmitsTheOptionalKeys() throws {
        let event = PaywallLinkOpenAttempted(source: .anchor, openedInApp: false, success: false, scheme: nil, url: nil)

        XCTAssertEqual(try wireProperties(for: event), NSDictionary(dictionary: [
            "source": "anchor",
            "openedInApp": false,
            "success": false,
        ]))
    }

    func testUrlForObservabilityCutsQueryAndFragment() throws {
        let url = try XCTUnwrap(URL(string: "https://tryhelium.com/pricing?token=abc123#section"))

        XCTAssertEqual(urlForObservability(url), "https://tryhelium.com/pricing")
    }

    // MARK: - FallbackPaywallsConfigured

    func testFullyPopulatedBundleCarriesGeneratedAtOrgDefaultUUIDCountAndMap() throws {
        let event = FallbackPaywallsConfigured(
            generatedAt: "2025-10-01T12:00:00Z",
            organizationID: "org-1",
            triggerToPaywallUUID: [
                HeliumFallbackViewManager.defaultFallbackTrigger: "default-uuid",
                "onboarding": "onboarding-uuid",
            ]
        )

        XCTAssertEqual(event.name, "fallback_paywalls_configured")
        XCTAssertEqual(try wireProperties(for: event), NSDictionary(dictionary: [
            "generatedAt": "2025-10-01T12:00:00Z",
            "organizationId": "org-1",
            "defaultPaywallUUID": "default-uuid",
            "triggerCount": 2,
            "triggerPaywallUUIDs": [
                HeliumFallbackViewManager.defaultFallbackTrigger: "default-uuid",
                "onboarding": "onboarding-uuid",
            ],
        ]))
    }

    func testBundleWithoutGeneratedAtOmitsTheKey() throws {
        let event = FallbackPaywallsConfigured(
            generatedAt: nil,
            organizationID: "org-1",
            triggerToPaywallUUID: ["onboarding": "onboarding-uuid"]
        )

        XCTAssertNil(try wireProperties(for: event)["generatedAt"])
    }

    func testBundleWithoutAnOrganizationOmitsTheKey() throws {
        let event = FallbackPaywallsConfigured(
            generatedAt: nil,
            organizationID: nil,
            triggerToPaywallUUID: ["onboarding": "onboarding-uuid"]
        )

        XCTAssertNil(try wireProperties(for: event)["organizationId"])
    }

    func testBundleWithNoDefaultTriggerOmitsTheDefaultPaywallUUID() throws {
        let event = FallbackPaywallsConfigured(
            generatedAt: nil,
            organizationID: nil,
            triggerToPaywallUUID: ["onboarding": "onboarding-uuid"]
        )

        XCTAssertNil(try wireProperties(for: event)["defaultPaywallUUID"])
    }

    func testDefaultTriggerWithoutAPaywallOmitsTheDefaultPaywallUUID() throws {
        let event = FallbackPaywallsConfigured(
            generatedAt: nil,
            organizationID: nil,
            triggerToPaywallUUID: [HeliumFallbackViewManager.defaultFallbackTrigger: nil]
        )

        XCTAssertNil(try wireProperties(for: event)["defaultPaywallUUID"])
    }

    func testTriggerWithNoResolvedPaywallCountsButIsAbsentFromTheMap() throws {
        let event = FallbackPaywallsConfigured(
            generatedAt: nil,
            organizationID: nil,
            triggerToPaywallUUID: ["configured": "configured-uuid", "unconfigured": nil]
        )

        XCTAssertEqual(try wireProperties(for: event), NSDictionary(dictionary: [
            "triggerCount": 2,
            "triggerPaywallUUIDs": ["configured": "configured-uuid"],
        ]))
    }

    func testEmptyBundleReportsZeroTriggersAndAnEmptyMap() throws {
        let event = FallbackPaywallsConfigured(
            generatedAt: nil,
            organizationID: nil,
            triggerToPaywallUUID: [:]
        )

        XCTAssertEqual(try wireProperties(for: event), NSDictionary(dictionary: [
            "triggerCount": 0,
            "triggerPaywallUUIDs": [String: String](),
        ]))
    }

    // MARK: - PaddlePrefetchOutcomeFinalized (CA ramp observability)

    func testOutcomeFinalizedCarriesCaRampFieldsWhenFlagOnAndCaliforniaFlows() throws {
        let event = PaddlePrefetchOutcomeFinalized(
            priceId: "pri_x",
            outcome: .ready,
            errorClass: nil,
            totalDurationMs: 42,
            ipGeoCountry: "US",
            ipGeoRegion: "CA",
            ipGeoPostal: "90210",
            californiaDetected: true,
            caConsentModalEnabled: true,
            consentRequired: "true"
        )

        XCTAssertEqual(event.name, "paddle_prefetch_outcome_finalized")
        XCTAssertEqual(try wireProperties(for: event), NSDictionary(dictionary: [
            "priceId": "pri_x",
            "outcome": "ready",
            "totalDurationMs": 42,
            "ipGeoCountry": "US",
            "ipGeoRegion": "CA",
            "ipGeoPostal": "90210",
            "californiaDetected": true,
            "caConsentModalEnabled": true,
            "consentRequired": "true",
        ]))
    }

    func testOutcomeFinalizedOmitsCaRampFieldsWhenAbsent() throws {
        // No rawBody (bandit-step / failed): the ramp keys drop rather than
        // emitting misleading false/absent values.
        let event = PaddlePrefetchOutcomeFinalized(
            priceId: "pri_x",
            outcome: .failed,
            errorClass: "SomeError",
            totalDurationMs: 7,
            ipGeoCountry: nil,
            ipGeoRegion: nil,
            ipGeoPostal: nil,
            californiaDetected: nil,
            caConsentModalEnabled: nil,
            consentRequired: nil
        )

        XCTAssertEqual(try wireProperties(for: event), NSDictionary(dictionary: [
            "priceId": "pri_x",
            "outcome": "failed",
            "totalDurationMs": 7,
            "errorClass": "SomeError",
        ]))
    }
}
