import XCTest
@testable import Helium

/// Locks the JSON contract for on-launch response fields the SDK depends on.
///
/// Why it exists:
///   `HeliumFetchedConfig` is `Codable` — Swift's default decoding maps property
///   names directly to JSON keys. That's a quiet contract: a typo in either
///   side (rename a Go field's JSON tag, rename a Swift property) silently
///   stops decoding without a compile-time signal.
///
///   This file exists to capture the parts of that contract the SDK
///   functionally relies on so a regression breaks a unit test instead of
///   a production paywall.
///
///   First field locked in: `paddleClientToken` (HEL-5326). The SDK uses it
///   to call Paddle's /transaction-checkout BFF directly during paywall
///   presentation, pre-warming the Apple Pay flow.
final class OnLaunchResponseDecodingTests: XCTestCase {

    // Minimal JSON skeleton with the fields HeliumFetchedConfig requires
    // (Codable's auto-synthesized decoder rejects missing non-optional keys).
    // Build dynamically so each test can layer one extra key on top without
    // re-typing the whole boilerplate.
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

        XCTAssertEqual(
            decoded.paddleClientToken,
            "test_paddle_client_token_abc123",
            "paddleClientToken must decode from the on-launch JSON's `paddleClientToken` key — used by the SDK pre-fetch path (HEL-5326)."
        )
    }

    func testPaddleClientTokenIsNilWhenAbsent() throws {
        // Bandit omits the key entirely when the org has no Paddle products
        // (omitempty on the Go side). SDK must treat that as nil, not crash.
        let json = try makeOnLaunchJSON(extras: [:])

        let decoded = try JSONDecoder().decode(HeliumFetchedConfig.self, from: json)

        XCTAssertNil(
            decoded.paddleClientToken,
            "paddleClientToken should be nil when the on-launch JSON omits the key (org has no Paddle products configured)."
        )
    }
}
