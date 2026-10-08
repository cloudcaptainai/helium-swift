import XCTest
@testable import Helium

/// Locks the JSON contract for on-launch response fields the SDK depends on.
final class OnLaunchResponseDecodingTests: XCTestCase {

    private func makeOnLaunchJSON(extras: [String: Any] = [:]) throws -> Data {
        var dict: [String: Any] = [
            "triggerToPaywalls": [:],
            "segmentBrowserWriteKey": "test_key",
            "segmentAnalyticsEndpoint": "https://test.example.com",
            "fetchedConfigID": UUID().uuidString,
        ]
        for (k, v) in extras { dict[k] = v }
        return try JSONSerialization.data(withJSONObject: dict, options: [])
    }

    // ---------- paddleClientToken contract ----------

    func testPaddleClientTokenDecodesFromJSON() throws {
        let json = try makeOnLaunchJSON(extras: [
            "paddleClientToken": "test_paddle_client_token_abc123",
        ])

        let decoded = try JSONDecoder().decode(HeliumFetchedConfig.self, from: json)

        XCTAssertEqual(decoded.paddleClientToken, "test_paddle_client_token_abc123")
    }

    func testPaddleClientTokenIsNilWhenAbsent() throws {
        let json = try makeOnLaunchJSON(extras: [:])

        let decoded = try JSONDecoder().decode(HeliumFetchedConfig.self, from: json)

        XCTAssertNil(decoded.paddleClientToken)
    }

    // ---------- paywallDiagnosticModalAllowedInTestFlight contract ----------

    func testDiagnosticModalPermissionDecodesFromJSON() throws {
        let json = try makeOnLaunchJSON(extras: [
            "paywallDiagnosticModalAllowedInTestFlight": false,
        ])

        let decoded = try JSONDecoder().decode(HeliumFetchedConfig.self, from: json)

        XCTAssertEqual(decoded.paywallDiagnosticModalAllowedInTestFlight, false)
    }

    /// Absent is how a customer's own fallbacks file always looks, so absent has to read as
    /// permission granted rather than withheld.
    func testDiagnosticModalPermissionIsNilWhenAbsent() throws {
        let json = try makeOnLaunchJSON(extras: [:])

        let decoded = try JSONDecoder().decode(HeliumFetchedConfig.self, from: json)

        XCTAssertNil(decoded.paywallDiagnosticModalAllowedInTestFlight)
    }

    // ---------- featureFlags contract ----------

    func testFeatureFlagsDecodeFromJSON() throws {
        let json = try makeOnLaunchJSON(extras: [
            "featureFlags": ["jsCrashFallback": true],
        ])

        let decoded = try JSONDecoder().decode(HeliumFetchedConfig.self, from: json)

        XCTAssertTrue(HeliumFeatureFlags.from(decoded.featureFlags).isEnabled(.jsCrashFallback))
    }

    func testFeatureFlagsAreNilWhenAbsent() throws {
        let json = try makeOnLaunchJSON(extras: [:])

        let decoded = try JSONDecoder().decode(HeliumFetchedConfig.self, from: json)

        XCTAssertNil(decoded.featureFlags)
        XCTAssertFalse(HeliumFeatureFlags.from(decoded.featureFlags).isEnabled(.jsCrashFallback))
    }

    // ---------- webSecondTry contract ----------

    /// One trigger's malformed second try costs that second try only, never the config.
    func testMalformedWebSecondTryLeavesTheRestOfTheConfigIntact() throws {
        func paywall(webSecondTry: Any) -> [String: Any] {
            [
                "paywallID": 1,
                "paywallTemplateName": "web_linked",
                "resolvedConfig": [String: Any](),
                "webProductsOfferedPaddle": ["pro_x:pri_y"],
                "webSecondTry": webSecondTry,
            ]
        }
        let json = try makeOnLaunchJSON(extras: [
            "triggerToPaywalls": [
                "malformed": paywall(webSecondTry: ["paywallUUID": 42, "conditions": "dismissed"]),
                "wellFormed": paywall(webSecondTry: [
                    "paywallUUID": "pw-uuid",
                    "paywallVersionUUID": "pwv-uuid",
                    "conditions": ["dismissed"],
                    "productsOfferedPaddle": ["pro_st:pri_st"],
                ]),
            ],
        ])

        let decoded = try JSONDecoder().decode(HeliumFetchedConfig.self, from: json)

        let malformed = try XCTUnwrap(decoded.triggerToPaywalls["malformed"])
        XCTAssertNil(malformed.webSecondTry)
        XCTAssertEqual(malformed.webProductsOfferedPaddle, ["pro_x:pri_y"])
        XCTAssertEqual(decoded.triggerToPaywalls["wellFormed"]?.webSecondTry?.productsOfferedPaddle, ["pro_st:pri_st"])
    }
}
