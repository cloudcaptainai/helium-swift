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

    // MARK: - Tags

    func testEveryEventFamilyDeclaresItsTags() {
        let expectations: [(any HeliumObservabilityEvent, [String])] = [
            (PaddlePrefetchStarted(priceIds: []), ["paddle_prefetch", "web_checkout"]),
            (WebCheckoutFlowStarted(provider: "paddle", productKey: "p"), ["web_checkout"]),
            (PaywallLinkOpenAttempted(source: .anchor, openedInApp: false, success: false, scheme: nil, url: nil), ["paywall_runtime"]),
            (PaywallWebProcessTerminated(loadAttempt: "first", wasContentLoaded: false), ["anomaly", "paywall_runtime"]),
            (EmbeddedPaywallManualDismissalEnabled(), ["config", "presentation"]),
            (FallbackPaywallsConfigured(generatedAt: nil, organizationID: nil, triggerToPaywallUUID: [:]), ["config", "fallback", "lifecycle"]),
        ]

        for (event, tags) in expectations {
            XCTAssertEqual(event.tags.map(\.rawValue).sorted(), tags, event.name)
        }
    }

    // MARK: - SdkApiCalled

    /// Wire names and tags for every public API event. Shared verbatim with the
    /// Android SDK; a change here needs the same change there.
    func testSdkApiMethodsMatchTheSharedCatalog() {
        let catalog = SdkApiMethod.allCases.map {
            "\($0.wireName) \($0.tags.map(\.rawValue).sorted().joined(separator: ","))"
        }

        XCTAssertEqual(catalog, [
            "sdk_api_initialize_called lifecycle,sdk_api",
            "sdk_api_present_paywall_called presentation,sdk_api",
            "sdk_api_hide_paywall_called presentation,sdk_api",
            "sdk_api_hide_all_paywalls_called presentation,sdk_api",
            "sdk_api_can_show_paywall_for_called presentation,sdk_api",
            "sdk_api_get_paywall_info_called presentation,sdk_api",
            "sdk_api_upsell_view_for_trigger_called deprecated_api,presentation,sdk_api",
            "sdk_api_reset_helium_called lifecycle,sdk_api",
            "sdk_api_add_helium_event_listener_called lifecycle,sdk_api",
            "sdk_api_remove_helium_event_listener_called lifecycle,sdk_api",
            "sdk_api_remove_all_helium_event_listeners_called lifecycle,sdk_api",
            "sdk_api_handle_deep_link_called deprecated_api,presentation,sdk_api",
            "sdk_api_handle_url_called sdk_api,web_checkout",
            "sdk_api_create_stripe_portal_session_called sdk_api,web_checkout",
            "sdk_api_create_paddle_portal_session_called sdk_api,web_checkout",
            "sdk_api_get_stripe_customer_id_called sdk_api,web_checkout",
            "sdk_api_get_paddle_customer_id_called sdk_api,web_checkout",
            "sdk_api_reset_stripe_entitlements_called sdk_api,web_checkout",
            "sdk_api_reset_paddle_entitlements_called sdk_api,web_checkout",
            "sdk_api_enable_external_web_checkout_called config,sdk_api,web_checkout",
            "sdk_api_disable_external_web_checkout_called config,sdk_api,web_checkout",
            "sdk_api_identity_set_user_id_called identity,sdk_api",
            "sdk_api_identity_set_revenue_cat_app_user_id_called identity,sdk_api",
            "sdk_api_identity_set_third_party_analytics_anonymous_id_called identity,sdk_api",
            "sdk_api_identity_set_app_account_token_called identity,sdk_api",
            "sdk_api_identity_set_user_traits_called identity,sdk_api",
            "sdk_api_identity_add_user_traits_called identity,sdk_api",
            "sdk_api_set_wrapper_sdk_info_called config,sdk_api",
        ])
    }

    func testSdkApiCalledCarriesCallContextAlongsideMethodProperties() throws {
        let event = SdkApiCalled(
            method: .hidePaywall,
            apiCallIndex: 7,
            callCountForMethod: 2,
            calledBeforeInitialize: false,
            methodProperties: ["result": true]
        )

        XCTAssertEqual(event.name, "sdk_api_hide_paywall_called")
        XCTAssertEqual(try wireProperties(for: event), NSDictionary(dictionary: [
            "result": true,
            "apiCallIndex": 7,
            "callCountForMethod": 2,
            "calledBeforeInitialize": false,
        ]))
    }

    func testPresentPaywallPropertiesNeverCarryTraitValues() throws {
        let config = PaywallPresentationConfig(customPaywallTraits: HeliumUserTraits(["email": "SENTINEL_VALUE"]))
        let props = presentPaywallObservabilityProperties(
            trigger: "onboarding",
            config: config,
            entryPoint: .presentPaywall,
            deprecatedOverload: false,
            hasEventHandlers: false,
            hasOnEntitled: false,
            hasOnPaywallNotShown: true
        )

        let wire = try XCTUnwrap(String(data: try JSONEncoder().encode(try SegmentJSON(props)), encoding: .utf8))
        XCTAssertFalse(wire.contains("SENTINEL_VALUE"))
        XCTAssertEqual(props["hasCustomPaywallTraits"] as? Bool, true)
        XCTAssertEqual(props["customPaywallTraitCount"] as? Int, 1)
        XCTAssertEqual(props["entryPoint"] as? String, "present_paywall")
        XCTAssertEqual(props["trigger"] as? String, "onboarding")
    }

    func testUserTraitsPropertiesCarrySortedKeysButNoValues() {
        let props = userTraitsObservabilityProperties(HeliumUserTraits(["plan": "pro", "age": 41]), viaMap: true)

        XCTAssertEqual(props["traitCount"] as? Int, 2)
        XCTAssertEqual(props["traitKeys"] as? String, "age,plan")
        XCTAssertEqual(props["viaMap"] as? Bool, true)
    }

    func testKeysForObservabilityCapsKeyCountAndKeyLength() {
        let keys = (0..<60).map { String(repeating: "k", count: 70) + "\($0)" }

        let parts = keysForObservability(keys).split(separator: ",")

        XCTAssertEqual(parts.count, 50)
        XCTAssertTrue(parts.allSatisfy { $0.count == 64 })
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
