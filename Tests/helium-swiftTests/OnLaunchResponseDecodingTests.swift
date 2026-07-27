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

    // ---------- allowCaliforniaWebCheckout contract (AB 2863 kill switch) ----------

    /// Decodes a single-trigger config whose paywall info carries the given
    /// `additionalPaywallFields` (any JSON shape), and returns that paywall info.
    private func decodePaywallInfo(additionalPaywallFields: Any?) throws -> HeliumPaywallInfo {
        var paywallInfo: [String: Any] = [
            "paywallID": 1,
            "paywallTemplateName": "test_paywall",
            "resolvedConfig": [:],
        ]
        if let additionalPaywallFields {
            paywallInfo["additionalPaywallFields"] = additionalPaywallFields
        }
        let json = try makeOnLaunchJSON(extras: [
            "triggerToPaywalls": ["test_trigger": paywallInfo],
        ])
        let decoded = try JSONDecoder().decode(HeliumFetchedConfig.self, from: json)
        return try XCTUnwrap(decoded.triggerToPaywalls["test_trigger"])
    }

    func testAllowCaliforniaWebCheckout_decodesTrue_fromAdditionalPaywallFields() throws {
        let info = try decodePaywallInfo(additionalPaywallFields: ["allowCaliforniaWebCheckout": true])

        XCTAssertTrue(info.allowCaliforniaWebCheckout, "Server flips the kill switch by setting the flag true")
    }

    func testAllowCaliforniaWebCheckout_defaultsFalse_whenAbsent() throws {
        // Absent flag => block. This is the binary-shipped default that keeps old
        // SDK versions safe until the bundler consent flow is confirmed live.
        let info = try decodePaywallInfo(additionalPaywallFields: nil)

        XCTAssertFalse(info.allowCaliforniaWebCheckout, "Absent flag must default to the blocking behavior")
    }

    func testAllowCaliforniaWebCheckout_isFalse_whenExplicitlyFalse() throws {
        let info = try decodePaywallInfo(additionalPaywallFields: ["allowCaliforniaWebCheckout": false])

        XCTAssertFalse(info.allowCaliforniaWebCheckout)
    }

    // Fail-closed contract: ONLY a genuine JSON boolean `true` may flip the kill
    // switch. Every ambiguous/wrong-typed shape must default to block. These pin
    // the strict (non-coercing) `.bool` accessor — a future swap to the coercing
    // `.boolValue` (which maps 1 / "true" / "yes" → true) would silently unblock
    // California buyers and these tests would catch it.

    func testAllowCaliforniaWebCheckout_isFalse_whenNull() throws {
        let info = try decodePaywallInfo(additionalPaywallFields: ["allowCaliforniaWebCheckout": NSNull()])

        XCTAssertFalse(info.allowCaliforniaWebCheckout, "Explicit JSON null must fail closed (block)")
    }

    func testAllowCaliforniaWebCheckout_isFalse_whenWrongTypedNumber() throws {
        let info = try decodePaywallInfo(additionalPaywallFields: ["allowCaliforniaWebCheckout": 1])

        XCTAssertFalse(info.allowCaliforniaWebCheckout, "A number must not be coerced to true — only a real JSON boolean flips the switch")
    }

    func testAllowCaliforniaWebCheckout_isFalse_whenWrongTypedString() throws {
        let info = try decodePaywallInfo(additionalPaywallFields: ["allowCaliforniaWebCheckout": "true"])

        XCTAssertFalse(info.allowCaliforniaWebCheckout, "String \"true\" must not be coerced — strict .bool fails closed")
    }

    func testAllowCaliforniaWebCheckout_isFalse_whenAdditionalFieldsNotAnObject() throws {
        let info = try decodePaywallInfo(additionalPaywallFields: ["unexpected", "array", "shape"])

        XCTAssertFalse(info.allowCaliforniaWebCheckout, "A non-object additionalPaywallFields must fail closed")
    }
}
