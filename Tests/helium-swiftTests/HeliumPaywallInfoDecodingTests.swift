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

    // MARK: - webSecondTry

    private let webSecondTryJSON: [String: Any] = [
        "paywallUUID": "pw-uuid",
        "paywallVersionUUID": "pwv-uuid",
        "paywallTemplateName": "Second Try",
        "conditions": ["dismissed", "applePayCancelled"],
        "productsOfferedPaddle": ["pro_x:pri_y"],
        "productsOfferedStripe": ["prod_x:price_y"],
    ]

    func test_GIVEN_webSecondTryPresent_WHEN_decoded_THEN_parsesEveryField() throws {
        let decoded = try decodePaywallInfo(extras: ["webSecondTry": webSecondTryJSON])

        XCTAssertEqual(decoded.webSecondTry, WebSecondTryInfo(
            paywallUUID: "pw-uuid",
            paywallVersionUUID: "pwv-uuid",
            paywallTemplateName: "Second Try",
            conditions: ["dismissed", "applePayCancelled"],
            productsOfferedPaddle: ["pro_x:pri_y"],
            productsOfferedStripe: ["prod_x:price_y"]
        ))
    }

    func test_GIVEN_webSecondTryAbsentOrNull_WHEN_decoded_THEN_isNil() throws {
        XCTAssertNil(try decodePaywallInfo().webSecondTry)
        XCTAssertNil(try decodePaywallInfo(extras: ["webSecondTry": NSNull()]).webSecondTry)
    }

    /// The server serializes an unset list as null.
    func test_GIVEN_webSecondTryWithNullListsAndNoTemplateName_WHEN_decoded_THEN_keepsTheRest() throws {
        let decoded = try decodePaywallInfo(extras: ["webSecondTry": [
            "paywallUUID": "pw-uuid",
            "paywallVersionUUID": "pwv-uuid",
            "conditions": NSNull(),
            "productsOfferedPaddle": NSNull(),
            "productsOfferedStripe": NSNull(),
        ]])

        XCTAssertEqual(decoded.webSecondTry, WebSecondTryInfo(paywallUUID: "pw-uuid", paywallVersionUUID: "pwv-uuid"))
    }

    /// The page matches the second try it compiled by these ids, so without them there is no second try.
    func test_GIVEN_webSecondTryMissingAnId_WHEN_decoded_THEN_isNil() throws {
        for missing in ["paywallUUID", "paywallVersionUUID"] {
            var json = webSecondTryJSON
            json.removeValue(forKey: missing)

            XCTAssertNil(try decodePaywallInfo(extras: ["webSecondTry": json]).webSecondTry, "missing: \(missing)")
        }
    }

    /// This field decodes alongside `resolvedConfig`, so a bad value has to cost the second try and
    /// not the entire paywall.
    func test_GIVEN_malformedWebSecondTry_WHEN_decoded_THEN_isNilAndNeverThrows() throws {
        func withField(_ key: String, _ value: Any) -> [String: Any] {
            var json = webSecondTryJSON
            json[key] = value
            return json
        }
        let hostileValues: [Any] = [
            "pw-uuid", 42, true, ["pw-uuid"], [String: Any](),
            withField("paywallUUID", 7),
            withField("conditions", "dismissed"),
            withField("conditions", ["dismissed", 1]),
            withField("productsOfferedPaddle", "pro_x:pri_y"),
            withField("productsOfferedStripe", [["id": "prod_x"]]),
        ]

        for value in hostileValues {
            let decoded = try decodePaywallInfo(extras: ["webSecondTry": value, "presentationStyle": "slideUp"])

            XCTAssertNil(decoded.webSecondTry, "value: \(value)")
            XCTAssertEqual(decoded.presentationStyle, .slideUp, "value: \(value)")
        }
    }

    private final class CapturingLogSink: HeliumLogSink, @unchecked Sendable {
        private let lock = NSLock()
        private var logged: [(level: HeliumLogLevel, message: String)] = []

        var webSecondTryWarnings: [String] {
            lock.withLock { logged.filter { $0.level == .warn && $0.message.contains("webSecondTry") }.map(\.message) }
        }

        func emit(
            level: HeliumLogLevel,
            category: HeliumLogCategory,
            message: String,
            metadata: [String: String],
            file: StaticString,
            function: StaticString,
            line: UInt
        ) {
            lock.withLock { logged.append((level, message)) }
        }
    }

    private func webSecondTryWarnings(decoding extras: [String: Any]) throws -> [String] {
        let sink = CapturingLogSink()
        HeliumLogger.setSink(sink)
        defer { HeliumLogger.setSink(HeliumOSLogSink()) }
        _ = try decodePaywallInfo(extras: extras)
        return sink.webSecondTryWarnings
    }

    /// A shape mismatch with the server should show up rather than silently costing the second try.
    func test_GIVEN_malformedWebSecondTry_WHEN_decoded_THEN_logsAWarning() throws {
        XCTAssertEqual(try webSecondTryWarnings(decoding: ["webSecondTry": ["paywallUUID": 7]]).count, 1)
    }

    func test_GIVEN_webSecondTryAbsentNullOrWellFormed_WHEN_decoded_THEN_logsNoWarning() throws {
        XCTAssertEqual(try webSecondTryWarnings(decoding: [:]), [])
        XCTAssertEqual(try webSecondTryWarnings(decoding: ["webSecondTry": NSNull()]), [])
        XCTAssertEqual(try webSecondTryWarnings(decoding: ["webSecondTry": webSecondTryJSON]), [])
    }
}
