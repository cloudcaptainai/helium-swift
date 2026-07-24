import XCTest
@testable import Helium

/// Locks the JSON contract for paywall fields the SDK shares with the Android client and the
/// paywall dashboard.
final class HeliumPaywallInfoDecodingTests: XCTestCase {

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
            "slideLeft": .slideLeft,
            "crossDissolve": .crossDissolve,
            "flipHorizontal": .flipHorizontal,
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
