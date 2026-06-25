import XCTest
@testable import Helium

/// Locks the JSON contract for the `productHapticsEnabled` paywall field, which the SDK shares
/// with the Android client and the paywall dashboard.
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

    func test_GIVEN_productHapticsEnabledPresent_WHEN_decoded_THEN_parsesList() throws {
        let json = try makePaywallInfoJSON(extras: [
            "productHapticsEnabled": ["select", "press"],
        ])

        let decoded = try JSONDecoder().decode(HeliumPaywallInfo.self, from: json)

        XCTAssertEqual(decoded.productHapticsEnabled, ["select", "press"])
    }

    func test_GIVEN_productHapticsEnabledAbsent_WHEN_decoded_THEN_isNil() throws {
        let json = try makePaywallInfoJSON()

        let decoded = try JSONDecoder().decode(HeliumPaywallInfo.self, from: json)

        XCTAssertNil(decoded.productHapticsEnabled)
    }
}
