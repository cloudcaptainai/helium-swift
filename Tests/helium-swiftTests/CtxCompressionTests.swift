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

    // MARK: - End-to-end: buildEnrichedCheckoutURL emits compressed ctx in URL fragment

    /// **HEL-5326 PII follow-up:** `buildEnrichedCheckoutURL` writes
    /// the compressed ctx to the URL **fragment** (after `#`), NOT the
    /// query string. The ctx contains PII (`customer.email`,
    /// `ip_geo_postal_code`) and hash fragments aren't sent in HTTP
    /// requests by browsers — so the payload doesn't appear in CDN
    /// logs, server access logs, or referer headers.
    ///
    /// This test locks in the wire move: ctx MUST be in the fragment,
    /// MUST NOT be in the query, and any pre-existing query items on
    /// the bundle URL are preserved (we don't accidentally clobber
    /// `helium_ios_bundle_id` or any other bundle URL params).
    func testBuildEnrichedCheckoutURL_emitsCtxInUrlFragmentNotQuery() async throws {
        Helium.lastApiKeyUsed = "test_api_key_for_fragment"
        defer { Helium.lastApiKeyUsed = nil }

        let provider: PaymentProviderConfig = .paddle
        let entitlements = HeliumPaymentEntitlementsSource(provider: provider)
        let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: entitlements)

        // Bundle URL with a pre-existing query item — production URLs
        // routinely carry `helium_ios_bundle_id` set by the bandit
        // server. The fragment write must leave this untouched.
        let baseURL = URL(string: "https://bundles-staging.heliumpaywall.com/o/p/bundle.html?helium_ios_bundle_id=com.example.app")!
        let templateEvent = PurchaseSucceededEvent(
            productId: "", triggerName: "t", paywallName: "P",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.purchaseEventPaymentProcessor
        )
        let analyticsEvent = HeliumAnalyticsManager.shared.buildLoggedEvent(
            for: templateEvent,
            paywallSession: PaywallSession(trigger: "t", paywallInfo: nil, fallbackType: .notFallback, presentationContext: .empty)
        )

        let url = try manager.buildEnrichedCheckoutURL(
            baseURL: baseURL, analyticsEvent: analyticsEvent,
            productKey: "pro_x:pri_y", triggerName: "t",
            successURL: "myapp://ok", cancelURL: "myapp://cancel",
            introOfferEligible: true, paddleBootstraps: nil
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        // 1) ctx is NOT in the query string.
        let queryNames: [String] = (components.queryItems ?? []).map { $0.name }
        XCTAssertFalse(queryNames.contains("ctx"),
                       "ctx must NOT appear in query string (PII leakage); got \(queryNames)")

        // 2) Pre-existing query items survive (helium_ios_bundle_id stays put).
        XCTAssertTrue(queryNames.contains("helium_ios_bundle_id"),
                      "Pre-existing helium_ios_bundle_id must be preserved; got \(queryNames)")

        // 3) ctx IS in the fragment, formatted as `ctx=<value>`.
        let fragment = try XCTUnwrap(components.fragment,
                                     "URL must have a fragment containing ctx")
        XCTAssertTrue(fragment.hasPrefix("ctx="),
                      "Fragment must start with `ctx=`; got `\(fragment)`")

        // 4) The fragment value round-trips through base64URL → deflate
        //    → JSON exactly as the old query-string wire did.
        let fragmentValue = String(fragment.dropFirst("ctx=".count))
        let compressed = try XCTUnwrap(base64URLDecode(fragmentValue),
                                       "Fragment value isn't valid base64URL")
        let decompressed = try decompressWithAppleZlib(compressed, originalSize: 8192)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: decompressed) as? [String: Any]
        )
        XCTAssertEqual(parsed[provider.initialProductKey] as? String, "pro_x:pri_y")
        XCTAssertEqual(parsed["successUrl"] as? String, "myapp://ok")
        XCTAssertEqual(parsed["cancelUrl"] as? String, "myapp://cancel")
        XCTAssertEqual(parsed["introOfferEligible"] as? Bool, true)
        XCTAssertNotNil(parsed["analytics"])
    }

    /// **HEL-5326 source_page alignment:** `buildEnrichedCheckoutURL`
    /// auto-appends `?helium_ios_bundle_id=<Bundle.main.bundleIdentifier>`
    /// to the URL when the base URL doesn't already carry it. This
    /// matches the `source_page` value the SDK sends to Paddle's
    /// `/transaction-checkout` (`bundles.clickthrough.to?helium_ios_bundle_id=<id>`),
    /// closing the "what we told Paddle source_page is" vs. "where
    /// the user actually lands" gap. Approved as non-PII on the
    /// 2026-05-08 Paddle call.
    ///
    /// Locked-in invariants:
    ///   1. Query param is present with a non-empty value.
    ///   2. Doesn't double-write when the base URL already has it.
    ///   3. Doesn't displace ctx — fragment still carries the
    ///      compressed payload.
    func testBuildEnrichedCheckoutURL_appendsHeliumIosBundleIdQueryParam() async throws {
        Helium.lastApiKeyUsed = "test_api_key_for_bundle_id"
        defer { Helium.lastApiKeyUsed = nil }

        let provider: PaymentProviderConfig = .paddle
        let entitlements = HeliumPaymentEntitlementsSource(provider: provider)
        let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: entitlements)

        // Base URL with NO helium_ios_bundle_id — the SDK should add it.
        let baseURL = URL(string: "https://bundles-staging.heliumpaywall.com/o/p/bundle.html")!
        let templateEvent = PurchaseSucceededEvent(
            productId: "", triggerName: "t", paywallName: "P",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.purchaseEventPaymentProcessor
        )
        let analyticsEvent = HeliumAnalyticsManager.shared.buildLoggedEvent(
            for: templateEvent,
            paywallSession: PaywallSession(trigger: "t", paywallInfo: nil, fallbackType: .notFallback, presentationContext: .empty)
        )

        let url = try manager.buildEnrichedCheckoutURL(
            baseURL: baseURL, analyticsEvent: analyticsEvent,
            productKey: "pro_x:pri_y", triggerName: "t",
            successURL: "ok", cancelURL: "no",
            introOfferEligible: true, paddleBootstraps: nil
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items: [URLQueryItem] = components.queryItems ?? []

        // 1) helium_ios_bundle_id query param is present and non-empty.
        let bundleIdItem = try XCTUnwrap(
            items.first(where: { $0.name == "helium_ios_bundle_id" }),
            "Expected helium_ios_bundle_id query param; got \(items.map { $0.name })"
        )
        let bundleIdValue = try XCTUnwrap(bundleIdItem.value)
        XCTAssertFalse(bundleIdValue.isEmpty, "helium_ios_bundle_id value must not be empty")
        // Matches the same value we put in ctx.iosBundleId — both come
        // from Bundle.main.bundleIdentifier with the same "unknown"
        // default when the bundle id is nil.
        XCTAssertEqual(bundleIdValue, Bundle.main.bundleIdentifier ?? "unknown")

        // 2) Fragment still has ctx (the bundle id query param doesn't
        //    displace the PII payload that lives in the fragment).
        let fragment = try XCTUnwrap(components.fragment)
        XCTAssertTrue(fragment.hasPrefix("ctx="))
    }

    /// Don't double-write `helium_ios_bundle_id` when the base URL
    /// already has it. The bandit server may include it on the
    /// `webPaywallBundleUrl` already; even if the value differs, the
    /// SDK should respect what the bundle URL was generated with
    /// rather than overwriting (single-writer principle for this
    /// query param).
    func testBuildEnrichedCheckoutURL_doesNotDoubleWriteHeliumIosBundleId() async throws {
        Helium.lastApiKeyUsed = "test_api_key_for_bundle_id_idempotent"
        defer { Helium.lastApiKeyUsed = nil }

        let provider: PaymentProviderConfig = .paddle
        let entitlements = HeliumPaymentEntitlementsSource(provider: provider)
        let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: entitlements)

        // Base URL ALREADY has helium_ios_bundle_id. SDK must NOT
        // add a duplicate (which URLComponents would happily allow).
        let baseURL = URL(string: "https://bundles-staging.heliumpaywall.com/o/p/bundle.html?helium_ios_bundle_id=com.preset.app")!
        let templateEvent = PurchaseSucceededEvent(
            productId: "", triggerName: "t", paywallName: "P",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.purchaseEventPaymentProcessor
        )
        let analyticsEvent = HeliumAnalyticsManager.shared.buildLoggedEvent(
            for: templateEvent,
            paywallSession: PaywallSession(trigger: "t", paywallInfo: nil, fallbackType: .notFallback, presentationContext: .empty)
        )

        let url = try manager.buildEnrichedCheckoutURL(
            baseURL: baseURL, analyticsEvent: analyticsEvent,
            productKey: "pro_x:pri_y", triggerName: "t",
            successURL: "ok", cancelURL: "no",
            introOfferEligible: true, paddleBootstraps: nil
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items: [URLQueryItem] = components.queryItems ?? []

        // Exactly ONE helium_ios_bundle_id, value preserved from the
        // base URL.
        let matches = items.filter { $0.name == "helium_ios_bundle_id" }
        XCTAssertEqual(matches.count, 1, "Must not double-write helium_ios_bundle_id; got \(matches.map { $0.value ?? "nil" })")
        XCTAssertEqual(matches.first?.value, "com.preset.app")
    }

    // MARK: - End-to-end: legacy `?ctx=` test (kept until SDK fully migrates)

    /// Integration test: the URL `buildEnrichedCheckoutURL` produces
    /// has a `?ctx=` query parameter, and base64URL-decoding it then
    /// deflate-raw-decompressing yields the original JSON.
    ///
    /// This is the wire contract the bundler consumes: base64URL of
    /// raw-DEFLATE-compressed JSON in `?ctx=`.
    func testBuildEnrichedCheckoutURL_emitsCompressedCtxAsBase64URL() async throws {
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

        // 1) URL fragment contains `ctx=<base64URL>` (HEL-5326 PII move).
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let fragment = try XCTUnwrap(components.fragment, "URL must have a ctx fragment")
        XCTAssertTrue(fragment.hasPrefix("ctx="),
                      "Fragment must start with `ctx=`; got `\(fragment)`")
        let ctxValue = String(fragment.dropFirst("ctx=".count))

        // 2) base64URL-decode the value back to compressed bytes.
        let compressed = try XCTUnwrap(base64URLDecode(ctxValue),
                                       "ctx value isn't valid base64URL")

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

        // Size check: compare the compressed `#ctx=` value length to
        // what an UNcompressed equivalent would have been. Lower bound
        // is 30% smaller (compression factor amplified by base64's 4:3
        // expansion ratio applying to both). Wire moved from query to
        // fragment in HEL-5326 — see emitsCtxInUrlFragmentNotQuery.
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let fragment = try XCTUnwrap(components.fragment, "URL must have a ctx fragment")
        XCTAssertTrue(fragment.hasPrefix("ctx="), "Fragment must start with `ctx=`; got `\(fragment)`")
        let ctxValue = String(fragment.dropFirst("ctx=".count))
        let compressedB64Length = ctxValue.count

        // Reconstruct what the uncompressed JSON would look like by
        // decompressing the URL and measuring its base64URL'd size.
        let compressed = try XCTUnwrap(base64URLDecode(ctxValue))
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

    // MARK: - paddleAlreadyEntitled map round-trips through ctx

    /// When a paywall has products the customer already owns, the SDK
    /// passes `paddleAlreadyEntitled` into `buildEnrichedCheckoutURL`
    /// alongside `paddleBootstraps`. The bundle uses it to short-
    /// circuit instantly when the user clicks an entitled product in
    /// Safari — no live bandit call, no loader.
    ///
    /// This test locks in the wire shape: the map appears in ctx as
    /// `paddleAlreadyEntitled`, sibling to `paddleBootstraps`, and
    /// each entry has `{ code, message }`.
    func testBuildEnrichedCheckoutURL_includesPaddleAlreadyEntitledWhenProvided() async throws {
        Helium.lastApiKeyUsed = "test_api_key_for_compression"
        defer { Helium.lastApiKeyUsed = nil }

        let provider: PaymentProviderConfig = .paddle
        let entitlements = HeliumPaymentEntitlementsSource(provider: provider)
        let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: entitlements)

        let baseURL = URL(string: "https://bundles-staging.heliumpaywall.com/o/p/bundle.html")!
        let templateEvent = PurchaseSucceededEvent(
            productId: "", triggerName: "t", paywallName: "P",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.purchaseEventPaymentProcessor
        )
        let analyticsEvent = HeliumAnalyticsManager.shared.buildLoggedEvent(
            for: templateEvent,
            paywallSession: PaywallSession(trigger: "t", paywallInfo: nil, fallbackType: .notFallback, presentationContext: .empty)
        )

        let alreadyEntitled: [String: Any] = [
            "pri_yearly": ["code": "duplicate_subscription", "message": "You already own yearly"],
        ]

        let url = try manager.buildEnrichedCheckoutURL(
            baseURL: baseURL, analyticsEvent: analyticsEvent,
            productKey: "pro_x:pri_monthly", triggerName: "t",
            successURL: "ok", cancelURL: "no",
            introOfferEligible: true,
            paddleBootstraps: nil,
            paddleAlreadyEntitled: alreadyEntitled
        )

        // Decode the URL fragment back to its ctx dict (HEL-5326).
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let fragment = try XCTUnwrap(components.fragment, "URL must have a ctx fragment")
        XCTAssertTrue(fragment.hasPrefix("ctx="), "Fragment must start with `ctx=`; got `\(fragment)`")
        let ctxValue = String(fragment.dropFirst("ctx=".count))
        let compressed = try XCTUnwrap(base64URLDecode(ctxValue))
        let decompressed = try decompressWithAppleZlib(compressed, originalSize: 16_384)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: decompressed) as? [String: Any])

        // The new field is present and round-trips intact.
        let entitledMap = try XCTUnwrap(parsed["paddleAlreadyEntitled"] as? [String: Any])
        let yearlyEntry = try XCTUnwrap(entitledMap["pri_yearly"] as? [String: Any])
        XCTAssertEqual(yearlyEntry["code"] as? String, "duplicate_subscription")
        XCTAssertEqual(yearlyEntry["message"] as? String, "You already own yearly")
    }

    /// When the SDK has nothing to report (no entitled products),
    /// `paddleAlreadyEntitled` is omitted from ctx — no point shipping
    /// an empty `{}`.
    func testBuildEnrichedCheckoutURL_omitsPaddleAlreadyEntitledWhenNil() async throws {
        Helium.lastApiKeyUsed = "test_api_key_for_compression"
        defer { Helium.lastApiKeyUsed = nil }

        let provider: PaymentProviderConfig = .paddle
        let entitlements = HeliumPaymentEntitlementsSource(provider: provider)
        let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: entitlements)

        let baseURL = URL(string: "https://bundles-staging.heliumpaywall.com/o/p/bundle.html")!
        let templateEvent = PurchaseSucceededEvent(
            productId: "", triggerName: "t", paywallName: "P",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.purchaseEventPaymentProcessor
        )
        let analyticsEvent = HeliumAnalyticsManager.shared.buildLoggedEvent(
            for: templateEvent,
            paywallSession: PaywallSession(trigger: "t", paywallInfo: nil, fallbackType: .notFallback, presentationContext: .empty)
        )

        let url = try manager.buildEnrichedCheckoutURL(
            baseURL: baseURL, analyticsEvent: analyticsEvent,
            productKey: "pro_x:pri_monthly", triggerName: "t",
            successURL: "ok", cancelURL: "no",
            introOfferEligible: true,
            paddleBootstraps: nil,
            paddleAlreadyEntitled: nil
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let fragment = try XCTUnwrap(components.fragment, "URL must have a ctx fragment")
        XCTAssertTrue(fragment.hasPrefix("ctx="), "Fragment must start with `ctx=`; got `\(fragment)`")
        let ctxValue = String(fragment.dropFirst("ctx=".count))
        let compressed = try XCTUnwrap(base64URLDecode(ctxValue))
        let decompressed = try decompressWithAppleZlib(compressed, originalSize: 8_192)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: decompressed) as? [String: Any])

        XCTAssertNil(parsed["paddleAlreadyEntitled"], "Omitted when caller passes nil")
    }

    // MARK: - Larger realistic payload (regression test)

    /// Production-shaped ctx with 2 paddleBootstraps + identity fields,
    /// totalling ~4.5 KB of JSON. Reproduces the wire shape we ship in
    /// `?ctx=`. If this round-trips cleanly, the helper is OK at that size;
    /// any trailing-byte corruption shows up as a JSON-parse failure here.
    func testDeflateRaw_roundTripsLargeRealisticPaywallCtx() throws {
        // Two-product bootstrap shape — matches the trimmed Paddle BFF
        // payload the SDK actually sends, padded to ~4.5 KB total.
        let bootstrap: [String: Any] = [
            "banditResponse": [
                "transactionId": "txn_01k_aaaaaaaaaaaaaaaaaaaaaaaa",
                "isKnownCustomer": false,
                "requestId": "req_01k_aaaaaaaaaaaaaaaaaaaaaaaa",
                "paddleCustomerId": "ctm_01k_aaaaaaaaaaaaaaaaaaaaaaaa",
            ],
            "paddleCheckoutResponse": [
                "data": [
                    "id": "che_01k_aaaaaaaaaaaaaaaaaaaaaaaa",
                    "transaction_id": "txn_01k_aaaaaaaaaaaaaaaaaaaaaaaa",
                    "status": "draft",
                    "currency_code": "USD",
                    "ip_geo_country_code": "US",
                    "ip_geo_postal_code": "94102",
                    "items": [
                        [
                            "billing_cycle": ["interval": "month", "frequency": 1],
                            "trial_period": ["interval": "day", "frequency": 7],
                            "price": [
                                "unit_price": ["amount": "499", "currency_code": "USD"],
                                "id": "pri_01k_aaaaaaaaaaaaaaaaaaaaaaaa",
                            ],
                        ],
                    ],
                    "totals": ["total": 0, "subtotal": 0, "tax": 0, "discount": 0],
                    "recurring_totals": ["total": 4.99, "subtotal": 4.99, "tax": 0],
                    "payments": [
                        "methods_available": [
                            ["type": "PI_APPLE_PAY",
                             "stripe_options": ["api_key": "pk_test_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                                                "country_code": "US"]],
                        ],
                    ],
                    "discount": NSNull(),
                    "customer": ["email": "buyer@example.com"],
                    "seller": ["name": "Acme Inc."],
                ],
            ],
        ]
        let ctx: [String: Any] = [
            "analytics": [
                "userId": "user_01k_aaaaaaaaaaaaaaaaaaaaaaaa",
                "heliumPersistentId": "01k_aaaaaaaaaaaaaaaaaaaaaaaa",
                "rcUserId": "rc_01k_aaaaaaaaaaaaaaaaaaaaaaaa",
                "appTransactionId": "apptxn_01k_aaaaaaaaaaaaaaaaaaaaaaaa",
                "organizationId": "4817a01c-719f-4976-a477-51a074ce476a",
                "iosBundleId": "com.helium.HeliumExample",
            ],
            "successUrl": "heliumexamplestripe://openapp",
            "cancelUrl": "heliumexamplestripe://openapp",
            "paymentFailureUrl": "heliumexamplestripe://openapp",
            "introOfferEligible": true,
            "initialPaddleProduct": "pro_01kppzadma4mq2yx61e5spzgxe:pri_01kpsb1rqm5f373rznmw63jnwt",
            "organizationId": "4817a01c-719f-4976-a477-51a074ce476a",
            "iosBundleId": "com.helium.HeliumExample",
            "paddleBootstraps": [
                "pri_01kpsb1rqm5f373rznmw63jnwt": bootstrap,
                "pri_01kpsgnvzp69jyatar1znzxtex": bootstrap,
            ],
        ]
        let json = try JSONSerialization.data(withJSONObject: ctx)
        XCTAssertGreaterThan(json.count, 1500, "Test fixture should produce a non-trivial JSON size")

        let compressed = try XCTUnwrap(CtxCompression.deflateRaw(json))
        let decompressed = try decompressWithAppleZlib(compressed, originalSize: json.count)

        XCTAssertEqual(json.count, decompressed.count, "Round-trip must preserve byte count exactly")
        XCTAssertEqual(json, decompressed, "Round-trip must preserve bytes exactly")

        // The bundler does this exact step on the decompressed output.
        // If the trailing bytes are corrupt, JSONSerialization will throw.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: decompressed),
                         "Decompressed payload must parse back to JSON")
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
    /// `decodeBase64UrlToBytes` does, so this test uses the same
    /// algorithm the production bundle uses when consuming `?ctx=`.
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
