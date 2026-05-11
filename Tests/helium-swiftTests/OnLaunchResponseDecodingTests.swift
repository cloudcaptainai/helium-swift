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
}
