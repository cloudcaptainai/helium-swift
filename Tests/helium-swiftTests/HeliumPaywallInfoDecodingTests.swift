import XCTest
@testable import Helium

/// Locks the JSON contract for paywall fields the SDK shares with the Android client and the
/// paywall dashboard.
final class HeliumPaywallInfoDecodingTests: XCTestCase {

    func testWebSecondTryConfigDecodesAndRejectsMalformedValues() throws {
        var events: [any HeliumObservabilityEvent] = []
        HeliumObservabilityManager.shared.unitTestTrackObserver = { events.append($0) }
        defer { HeliumObservabilityManager.shared.unitTestTrackObserver = nil }
        let secondTry: [String: Any] = [
            "paywallUUID": "paywall-b",
            "paywallID": 42,
            "paywallTemplateName": "Second",
            "paywallVersionUUID": "version-b",
            "bundleUrl": "https://example.com/b",
            "productsOfferedPaddle": ["pro_b:pri_b"],
            "productsOfferedStripe": [String](),
            "showOn": ["dismissed"],
        ]
        let decoded = try decodePaywallInfo(extras: ["webSecondTryConfig": secondTry])
        XCTAssertEqual(decoded.webSecondTryConfig?.paywallUUID, "paywall-b")
        XCTAssertEqual(decoded.webSecondTryConfig?.paywallID, 42)
        XCTAssertEqual(decoded.webSecondTryConfig?.paywallTemplateName, "Second")
        XCTAssertEqual(decoded.webSecondTryConfig?.productsOfferedPaddle, ["pro_b:pri_b"])
        XCTAssertEqual(decoded.webSecondTryConfig?.showOn, ["dismissed"])
        var older = secondTry
        older.removeValue(forKey: "paywallID")
        older.removeValue(forKey: "paywallTemplateName")
        let oldConfig = try XCTUnwrap(decodePaywallInfo(extras: ["webSecondTryConfig": older]).webSecondTryConfig)
        XCTAssertNil(oldConfig.paywallID)
        XCTAssertNil(oldConfig.paywallTemplateName)
        XCTAssertNil(try decodePaywallInfo().webSecondTryConfig)
        XCTAssertNil(try decodePaywallInfo(extras: ["webSecondTryConfig": NSNull()]).webSecondTryConfig)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(try decodePaywallInfo(extras: ["webSecondTryConfig": ["paywallUUID": 4]]).webSecondTryConfig)
        var invalidURL = secondTry
        invalidURL["bundleUrl"] = "not-a-url"
        XCTAssertNil(try decodePaywallInfo(extras: ["webSecondTryConfig": invalidURL]).webSecondTryConfig)
        XCTAssertEqual(events.map(\.name), ["web_second_try_config_decode_failed", "web_second_try_config_decode_failed"])
        XCTAssertEqual(events[0].properties["codingPath"] as? String, "webSecondTryConfig.paywallUUID")
        XCTAssertEqual(events[0].properties["errorType"] as? String, "typeMismatch")
        XCTAssertTrue((events[0].properties["errorDescription"] as? String)?.contains("Expected to decode String") == true)
        XCTAssertEqual(events[1].properties["errorType"] as? String, "dataCorrupted")
        XCTAssertEqual(events[1].properties["codingPath"] as? String, "webSecondTryConfig.bundleUrl")
    }

    func testWebSecondTryDecodeFailureIncludesTriggerAndMissingKey() throws {
        var events: [any HeliumObservabilityEvent] = []
        HeliumObservabilityManager.shared.unitTestTrackObserver = { events.append($0) }
        defer { HeliumObservabilityManager.shared.unitTestTrackObserver = nil }
        let info = try JSONSerialization.jsonObject(with: makePaywallInfoJSON(extras: ["webSecondTryConfig": ["paywallUUID": "b", "paywallVersionUUID": "v", "bundleUrl": "https://example.com/b", "productsOfferedPaddle": [], "productsOfferedStripe": []]]))
        let data = try JSONSerialization.data(withJSONObject: ["triggerToPaywalls": ["on_open": info]])
        let result = try JSONDecoder().decode([String: [String: HeliumPaywallInfo]].self, from: data)
        XCTAssertNil(result["triggerToPaywalls"]?["on_open"]?.webSecondTryConfig)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.properties["codingPath"] as? String, "triggerToPaywalls.on_open.webSecondTryConfig.showOn")
        XCTAssertEqual(event.properties["errorType"] as? String, "keyNotFound")
        XCTAssertTrue((event.properties["errorDescription"] as? String)?.contains("showOn") == true)
    }

    private func makePaywallInfoJSON(extras: [String: Any] = [:]) throws -> Data {
        var dict: [String: Any] = [
            "paywallID": 1,
            "paywallTemplateName": "test_paywall",
            "resolvedConfig": [String: Any](),
        ]
        for (k, v) in extras { dict[k] = v }
        return try JSONSerialization.data(withJSONObject: dict, options: [])
    }

    private func decodePaywallInfo(extras: [String: Any] = [:]) throws -> HeliumPaywallInfo {
        return try JSONDecoder().decode(HeliumPaywallInfo.self, from: makePaywallInfoJSON(extras: extras))
    }

    // MARK: - productHapticsEnabled

    func test_GIVEN_productHapticsEnabledPresent_WHEN_decoded_THEN_parsesList() throws {
        let decoded = try decodePaywallInfo(extras: ["productHapticsEnabled": ["select", "press"]])

        XCTAssertEqual(decoded.productHapticsEnabled, ["select", "press"])
    }

    func test_GIVEN_productHapticsEnabledAbsent_WHEN_decoded_THEN_isNil() throws {
        let decoded = try decodePaywallInfo()

        XCTAssertNil(decoded.productHapticsEnabled)
    }

    // MARK: - presentationStyle

    func test_GIVEN_presentationStylePresent_WHEN_decoded_THEN_parsesEachKnownStyle() throws {
        let expected: [String: HeliumPresentationStyle] = [
            "slideUp": .slideUp,
            "slideLeft": .slideLeft
        ]

        for (raw, style) in expected {
            let decoded = try decodePaywallInfo(extras: ["presentationStyle": raw])

            XCTAssertEqual(decoded.presentationStyle, style, "raw value: \(raw)")
        }
    }

    func test_GIVEN_presentationStyleAbsent_WHEN_decoded_THEN_isNil() throws {
        let decoded = try decodePaywallInfo()

        XCTAssertNil(decoded.presentationStyle)
    }

    func test_GIVEN_presentationStyleExplicitlyNull_WHEN_decoded_THEN_isNil() throws {
        let decoded = try decodePaywallInfo(extras: ["presentationStyle": NSNull()])

        XCTAssertNil(decoded.presentationStyle)
    }

    /// A dashboard value written for a newer SDK reads as unset, leaving the paywall on the default
    /// animation instead of failing to decode.
    func test_GIVEN_presentationStyleFromNewerDashboard_WHEN_decoded_THEN_isNil() throws {
        let decoded = try decodePaywallInfo(extras: ["presentationStyle": "teleport"])

        XCTAssertNil(decoded.presentationStyle)
    }

    func test_GIVEN_presentationStyleWrongJSONType_WHEN_decoded_THEN_isNil() throws {
        XCTAssertNil(try decodePaywallInfo(extras: ["presentationStyle": 42]).presentationStyle)
        XCTAssertNil(try decodePaywallInfo(extras: ["presentationStyle": true]).presentationStyle)
        XCTAssertNil(try decodePaywallInfo(extras: ["presentationStyle": ["slideUp"]]).presentationStyle)
        XCTAssertNil(try decodePaywallInfo(extras: ["presentationStyle": ["a": 1]]).presentationStyle)
    }

    /// This field decodes alongside `resolvedConfig`, so a bad value has to cost the animation and
    /// not the entire paywall.
    func test_GIVEN_anyPresentationStyleValue_WHEN_decoded_THEN_neverThrows() {
        let hostileValues: [Any] = ["teleport", "", 42, true, NSNull(), ["slideUp"], ["a": 1]]

        for value in hostileValues {
            XCTAssertNoThrow(
                try decodePaywallInfo(extras: ["presentationStyle": value]),
                "value: \(value)"
            )
        }
    }

    /// The wire contract is camelCase. Other spellings are not silently accepted, so a dashboard
    /// emitting the wrong casing shows up as the default animation rather than appearing to work.
    func test_GIVEN_presentationStyleInAnotherCasing_WHEN_decoded_THEN_isNil() throws {
        for raw in ["SLIDE_UP", "slide_left", "SlideLeft", "slideup"] {
            let decoded = try decodePaywallInfo(extras: ["presentationStyle": raw])

            XCTAssertNil(decoded.presentationStyle, "raw value: \(raw)")
        }
    }
}
