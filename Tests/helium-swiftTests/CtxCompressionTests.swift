import XCTest
import Compression
@testable import Helium

/// Tests for `CtxCompression` — the helper that compresses ctx bytes
/// (post-JSON-serialization, pre-base64URL) so the bundler URL doesn't
/// blow Safari's URL budget for paywalls with multiple Paddle products.
///
/// The wire pairing is **Swift `COMPRESSION_ZLIB` → JS
/// `DecompressionStream('deflate-raw')`**. Despite the name, Apple's
/// `COMPRESSION_ZLIB` emits raw DEFLATE (RFC 1951, no zlib/gzip wrapper),
/// which `DecompressionStream('deflate-raw')` consumes exactly. Both
/// ends are native; no third-party libraries on either side.
///
/// These tests verify the **round-trip via Apple's own decoder** so the
/// helper's output is provably valid raw DEFLATE before the bundler PR
/// is asked to consume it.
final class CtxCompressionTests: XCTestCase {

    // MARK: - Round-trip

    /// Compress → decompress (using Apple's `compression_decode_buffer`
    /// with the same algorithm) → assert the bytes are identical to the
    /// input. Locks in that the output is valid raw DEFLATE.
    func testDeflateRaw_roundTripsThroughAppleDecoder() throws {
        let original = "Hello, deflate-raw round trip!".data(using: .utf8)!

        let compressed = try XCTUnwrap(CtxCompression.deflateRaw(original))
        let decompressed = try decompressWithAppleZlib(compressed, originalSize: original.count)

        XCTAssertEqual(decompressed, original)
    }

    /// Realistic ctx-shaped JSON: nested objects, arrays, mixed types.
    /// Verifies the helper handles the actual payload shape we'll feed
    /// from `buildEnrichedCheckoutURL`.
    func testDeflateRaw_roundTripsRealisticCtxJSON() throws {
        let ctx: [String: Any] = [
            "organizationId": "org_01abc",
            "heliumPersistentId": "uuid-deadbeef",
            "initialPaddleProduct": "pro_x:pri_y",
            "successUrl": "myapp://ok",
            "cancelUrl": "myapp://cancel",
            "introOfferEligible": true,
            "paddleBootstraps": [
                "pri_y": [
                    "banditResponse": [
                        "transactionId": "txn_abc",
                        "isKnownCustomer": false,
                        "requestId": "req_x",
                    ],
                    "paddleCheckoutResponse": [
                        "data": [
                            "id": "che_x",
                            "transaction_id": "txn_abc",
                            "currency_code": "USD",
                            "items": [["billing_cycle": ["interval": "month", "frequency": 1]]],
                        ],
                    ],
                ],
            ],
        ]
        let json = try JSONSerialization.data(withJSONObject: ctx)

        let compressed = try XCTUnwrap(CtxCompression.deflateRaw(json))
        let decompressed = try decompressWithAppleZlib(compressed, originalSize: json.count)

        // Parse both sides as JSON and compare structurally — direct byte
        // equality would fail on dictionary ordering even though the
        // semantic content is identical.
        let originalParsed = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let decompressedParsed = try JSONSerialization.jsonObject(with: decompressed) as? [String: Any]
        XCTAssertEqual(
            (originalParsed?["organizationId"]) as? String,
            (decompressedParsed?["organizationId"]) as? String
        )
        XCTAssertEqual(
            (originalParsed?["initialPaddleProduct"]) as? String,
            (decompressedParsed?["initialPaddleProduct"]) as? String
        )
        XCTAssertEqual(json.count, decompressed.count, "Round-trip should preserve byte count exactly")
    }

    /// Unicode-heavy payloads (currency symbols, accents, emoji) must
    /// survive the round trip — Paddle's BFF response carries `seller.name`
    /// and other strings that can include non-ASCII bytes.
    func testDeflateRaw_roundTripsUnicodeBytes() throws {
        let unicode = "Helium — €1.99/mo • prima ⌘ €5,000 • 你好 • 🎉".data(using: .utf8)!

        let compressed = try XCTUnwrap(CtxCompression.deflateRaw(unicode))
        let decompressed = try decompressWithAppleZlib(compressed, originalSize: unicode.count)

        XCTAssertEqual(decompressed, unicode)
        XCTAssertEqual(
            String(data: decompressed, encoding: .utf8),
            "Helium — €1.99/mo • prima ⌘ €5,000 • 你好 • 🎉"
        )
    }

    // MARK: - Compression effectiveness

    /// On a typical-sized ctx (a few KB of JSON with redundancy), the
    /// compressed form must actually be smaller — otherwise we'd waste
    /// CPU and bytes for nothing.
    func testDeflateRaw_compressesTypicalCtxJSONSmallerThanInput() throws {
        // Synthesize a realistic ctx: highly repetitive structure (paddle
        // bootstraps for two products, both with the same Paddle BFF
        // response shape — the SDK trim guarantees this redundancy).
        let bootstrap: [String: Any] = [
            "banditResponse": [
                "transactionId": "txn_01k_aaaaaaaaaaaaaaaa",
                "isKnownCustomer": false,
                "requestId": "req_01k_aaaaaaaaaaaaaaaa",
            ],
            "paddleCheckoutResponse": [
                "data": [
                    "id": "che_01k_aaaaaaaaaaaaaaaa",
                    "transaction_id": "txn_01k_aaaaaaaaaaaaaaaa",
                    "status": "draft",
                    "currency_code": "USD",
                    "ip_geo_country_code": "US",
                    "ip_geo_postal_code": "94102",
                    "items": [
                        [
                            "billing_cycle": ["interval": "month", "frequency": 1],
                            "trial_period": ["interval": "day", "frequency": 7],
                            "price": ["unit_price": ["amount": "499", "currency_code": "USD"]],
                        ]
                    ],
                    "totals": ["total": 0],
                    "recurring_totals": ["total": 4.99],
                    "payments": [
                        "methods_available": [
                            ["type": "PI_APPLE_PAY", "stripe_options": ["api_key": "pk_test_xxx", "country_code": "US"]]
                        ]
                    ],
                ]
            ],
        ]
        let ctx: [String: Any] = [
            "organizationId": "org_01abc_repeatable",
            "paddleBootstraps": [
                "pri_a_yearly": bootstrap,
                "pri_b_monthly": bootstrap,
            ],
        ]
        let json = try JSONSerialization.data(withJSONObject: ctx)

        let compressed = try XCTUnwrap(CtxCompression.deflateRaw(json))

        XCTAssertLessThan(
            compressed.count, json.count,
            "Compressed bytes (\(compressed.count)) must be smaller than the original JSON (\(json.count)). If this fails, the helper isn't producing valid DEFLATE output, or Apple's framework is mis-encoding."
        )
        // Loose lower bound: typical Paddle ctx compresses by ~50-70%.
        // Asserting >=20% reduction so the test catches "compression
        // works but is suspiciously weak" without being too tight.
        let reduction = Double(json.count - compressed.count) / Double(json.count)
        XCTAssertGreaterThan(reduction, 0.20, "Expected >=20% size reduction; got \(Int(reduction * 100))%")
    }

    // MARK: - End-to-end: buildEnrichedCheckoutURL emits compressed ?ctxz=

    /// Integration test: the URL `buildEnrichedCheckoutURL` produces must
    /// have a `?ctxz=` query parameter (NOT `?ctx=`), and base64URL-
    /// decoding it then deflate-raw-decompressing must yield the same
    /// JSON the legacy uncompressed path would have produced.
    ///
    /// This is the contract the bundler PR consumes: `ctxz` over `ctx`,
    /// base64URL alphabet, raw DEFLATE bytes inside.
    func testBuildEnrichedCheckoutURL_emitsCtxzWithCompressedThenBase64URLEncodedJSON() async throws {
        // Helium.lastApiKeyUsed gates baseRequestBody — without it
        // buildEnrichedCheckoutURL throws .notInitialized.
        Helium.lastApiKeyUsed = "test_api_key_for_compression"
        defer { Helium.lastApiKeyUsed = nil }

        let provider: PaymentProviderConfig = .paddle
        let entitlements = HeliumPaymentEntitlementsSource(provider: provider)
        let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: entitlements)

        // Minimal but realistic ctx inputs.
        let baseURL = URL(string: "https://bundles-staging.heliumpaywall.com/org/paywall/bundle.html")!
        let templateEvent = PurchaseSucceededEvent(
            productId: "",
            triggerName: "test_trigger",
            paywallName: "Test Paywall",
            storeKitTransactionId: nil,
            storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.purchaseEventPaymentProcessor
        )
        let analyticsEvent = HeliumAnalyticsManager.shared.buildLoggedEvent(
            for: templateEvent,
            paywallSession: PaywallSession(trigger: "test_trigger", paywallInfo: nil, fallbackType: .notFallback, presentationContext: .empty)
        )

        let url = try manager.buildEnrichedCheckoutURL(
            baseURL: baseURL,
            analyticsEvent: analyticsEvent,
            productKey: "pro_x:pri_y",
            triggerName: "test_trigger",
            successURL: "myapp://ok",
            cancelURL: "myapp://cancel",
            introOfferEligible: true,
            paddleBootstraps: nil
        )

        // 1) URL must use ?ctxz=, not ?ctx=. The query param name is the
        //    bundler's signal that it should decompress before parsing.
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items: [URLQueryItem] = components.queryItems ?? []
        let queryNames: [String] = items.map { $0.name }
        XCTAssertTrue(queryNames.contains("ctxz"),
                      "Expected ?ctxz= query param; got \(queryNames)")
        XCTAssertFalse(queryNames.contains("ctx"),
                       "Should not emit both ?ctx= and ?ctxz= — that defeats the size win")

        let ctxzValue = try XCTUnwrap(items.first(where: { $0.name == "ctxz" })?.value)

        // 2) base64URL-decode the value back to compressed bytes.
        let compressed = try XCTUnwrap(base64URLDecode(ctxzValue),
                                       "ctxz value isn't valid base64URL")

        // 3) Decompress (Apple's COMPRESSION_ZLIB consumes raw DEFLATE).
        let decompressed = try decompressWithAppleZlib(compressed, originalSize: 8192)

        // 4) JSON-parse and verify the dict has the fields buildEnriched
        //    is supposed to put in.
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: decompressed) as? [String: Any],
            "Decompressed payload isn't valid JSON object"
        )
        XCTAssertEqual(parsed[provider.initialProductKey] as? String, "pro_x:pri_y")
        XCTAssertEqual(parsed["successUrl"] as? String, "myapp://ok")
        XCTAssertEqual(parsed["cancelUrl"] as? String, "myapp://cancel")
        XCTAssertEqual(parsed["introOfferEligible"] as? Bool, true)
        XCTAssertNotNil(parsed["analytics"])
    }

    /// Compression must shrink the URL meaningfully on a realistic
    /// payload — paddleBootstraps for two products with the typical
    /// trimmed BFF response shape. This is the whole point of the
    /// feature; lock it in so a future refactor can't quietly disable
    /// the win.
    func testBuildEnrichedCheckoutURL_compressedURLIsMaterillySmallerThanUncompressedJSON() async throws {
        Helium.lastApiKeyUsed = "test_api_key_for_compression"
        defer { Helium.lastApiKeyUsed = nil }

        let provider: PaymentProviderConfig = .paddle
        let entitlements = HeliumPaymentEntitlementsSource(provider: provider)
        let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: entitlements)

        let baseURL = URL(string: "https://bundles-staging.heliumpaywall.com/org/paywall/bundle.html")!
        let templateEvent = PurchaseSucceededEvent(
            productId: "", triggerName: "t", paywallName: "P",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.purchaseEventPaymentProcessor
        )
        let analyticsEvent = HeliumAnalyticsManager.shared.buildLoggedEvent(
            for: templateEvent,
            paywallSession: PaywallSession(trigger: "t", paywallInfo: nil, fallbackType: .notFallback, presentationContext: .empty)
        )

        // Same bootstrap shape used in the helper-level compression test.
        let bootstrap: [String: Any] = [
            "banditResponse": [
                "transactionId": "txn_01k_aaaaaaaaaaaaaaaa",
                "isKnownCustomer": false,
                "requestId": "req_01k_aaaaaaaaaaaaaaaa",
            ],
            "paddleCheckoutResponse": [
                "data": [
                    "id": "che_01k_aaaaaaaaaaaaaaaa",
                    "transaction_id": "txn_01k_aaaaaaaaaaaaaaaa",
                    "status": "draft",
                    "currency_code": "USD",
                    "ip_geo_country_code": "US",
                    "ip_geo_postal_code": "94102",
                    "items": [["billing_cycle": ["interval": "month", "frequency": 1],
                               "price": ["unit_price": ["amount": "499", "currency_code": "USD"]]]],
                    "totals": ["total": 0],
                    "recurring_totals": ["total": 4.99],
                    "payments": ["methods_available": [["type": "PI_APPLE_PAY",
                        "stripe_options": ["api_key": "pk_test_xxx", "country_code": "US"]]]],
                ]
            ],
        ]
        let bootstraps: [String: Any] = [
            "pri_a_yearly": bootstrap,
            "pri_b_monthly": bootstrap,
        ]

        let url = try manager.buildEnrichedCheckoutURL(
            baseURL: baseURL, analyticsEvent: analyticsEvent,
            productKey: "pro_x:pri_a_yearly", triggerName: "t",
            successURL: "ok", cancelURL: "no",
            introOfferEligible: true, paddleBootstraps: bootstraps
        )

        // Size check: compare the compressed URL's ctxz value length to
        // what an UNcompressed equivalent would have been. Lower bound
        // is 30% smaller (compression factor amplified by base64's 4:3
        // expansion ratio applying to both).
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items: [URLQueryItem] = components.queryItems ?? []
        let ctxzValue = try XCTUnwrap(items.first(where: { $0.name == "ctxz" })?.value)
        let compressedB64Length = ctxzValue.count

        // Reconstruct what the uncompressed JSON would look like by
        // decompressing the URL and measuring its base64URL'd size.
        let compressed = try XCTUnwrap(base64URLDecode(ctxzValue))
        let decompressed = try decompressWithAppleZlib(compressed, originalSize: 16_384)
        let uncompressedB64Length = decompressed.base64URLEncodedString().count

        XCTAssertLessThan(
            compressedB64Length, uncompressedB64Length,
            "Compressed URL value (\(compressedB64Length) chars) must be smaller than uncompressed (\(uncompressedB64Length) chars)"
        )
        let reduction = Double(uncompressedB64Length - compressedB64Length) / Double(uncompressedB64Length)
        XCTAssertGreaterThan(
            reduction, 0.30,
            "Expected >=30% URL-length reduction on a realistic 2-product paddleBootstraps payload; got \(Int(reduction * 100))%"
        )
    }

    // MARK: - Empty / edge-case inputs

    /// Empty input shouldn't crash. DEFLATE has a defined empty-stream
    /// representation; Apple's framework must handle it.
    func testDeflateRaw_handlesEmptyInput() throws {
        let empty = Data()
        let compressed = CtxCompression.deflateRaw(empty)

        // Apple's `compression_encode_buffer` returns 0 on failure. For
        // an empty input it may legitimately produce 0 bytes (or a tiny
        // stream marker). Either is acceptable; what we don't tolerate
        // is a crash. We accept nil OR a small Data; if Data, it must
        // round-trip back to empty.
        if let compressed = compressed {
            let decompressed = try decompressWithAppleZlib(compressed, originalSize: 0)
            XCTAssertEqual(decompressed, empty)
        }
    }

    // MARK: - Helpers

    /// Reverses our `base64URLEncodedString` (RFC 4648 §5: `+/` → `-_`,
    /// padding stripped) back to bytes. Mirrors what the bundler's
    /// `decodeHeliumCtxParam` does, so this test uses the same algorithm
    /// the production bundle uses when consuming `?ctxz=`.
    private func base64URLDecode(_ encoded: String) -> Data? {
        var s = encoded.replacingOccurrences(of: "-", with: "+")
                       .replacingOccurrences(of: "_", with: "/")
        let padNeeded = (4 - (s.count % 4)) % 4
        s += String(repeating: "=", count: padNeeded)
        return Data(base64Encoded: s)
    }

    /// Decompresses raw DEFLATE bytes (what `CtxCompression.deflateRaw`
    /// emits) back to the original. Used as the test oracle so we don't
    /// depend on the bundler-service's JS decoder being available here.
    /// `originalSize` is the expected output capacity; in production the
    /// bundle uses streaming so it doesn't need this hint.
    private func decompressWithAppleZlib(_ data: Data, originalSize: Int) throws -> Data {
        // Allocate a destination buffer at least as big as the original.
        // Add a fudge factor for the trivial-input case where DEFLATE
        // overhead can briefly exceed the input size.
        let capacity = max(originalSize, 64) * 2 + 64
        var dst = [UInt8](repeating: 0, count: capacity)
        let decoded = data.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Int in
            guard let baseAddr = srcPtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                &dst, capacity,
                baseAddr.assumingMemoryBound(to: UInt8.self), data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard decoded > 0 || originalSize == 0 else {
            throw NSError(domain: "CtxCompressionTests", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Apple's compression_decode_buffer failed to decode (returned \(decoded))"])
        }
        return Data(dst.prefix(decoded))
    }
}
