import XCTest
import Compression
@testable import Helium

final class CtxCompressionTests: XCTestCase {

    // MARK: - Round-trip

    func testDeflateRaw_roundTripsThroughAppleDecoder() throws {
        let original = "Hello, deflate-raw round trip!".data(using: .utf8)!

        let compressed = try XCTUnwrap(CtxCompression.deflateRaw(original))
        let decompressed = try decompressWithAppleZlib(compressed, originalSize: original.count)

        XCTAssertEqual(decompressed, original)
    }

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

        // Parse both sides as JSON; byte equality fails on dictionary ordering.
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

    func testDeflateRaw_compressesTypicalCtxJSONSmallerThanInput() throws {
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
            "Compressed bytes (\(compressed.count)) must be smaller than the original JSON (\(json.count))."
        )
        let reduction = Double(json.count - compressed.count) / Double(json.count)
        XCTAssertGreaterThan(reduction, 0.20, "Expected >=20% size reduction; got \(Int(reduction * 100))%")
    }

    // MARK: - End-to-end: buildEnrichedCheckoutURL emits compressed ctx in URL fragment

    func testBuildEnrichedCheckoutURL_emitsCtxInUrlFragmentNotQuery() async throws {
        Helium.lastApiKeyUsed = "test_api_key_for_fragment"
        defer { Helium.lastApiKeyUsed = nil }

        let provider: PaymentProviderConfig = .paddle
        let entitlements = HeliumPaymentEntitlementsSource(provider: provider)
        let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: entitlements)

        let baseURL = URL(string: "https://bundles-staging.heliumpaywall.com/o/p/bundle.html?helium_ios_bundle_id=com.example.app")!
        let templateEvent = PurchaseSucceededEvent(
            productId: "", triggerName: "t", paywallName: "P",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.kind
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

        let queryNames: [String] = (components.queryItems ?? []).map { $0.name }
        XCTAssertFalse(queryNames.contains("ctx"),
                       "ctx must NOT appear in query string; got \(queryNames)")

        XCTAssertTrue(queryNames.contains("helium_ios_bundle_id"),
                      "Pre-existing helium_ios_bundle_id must be preserved; got \(queryNames)")

        let fragment = try XCTUnwrap(components.fragment,
                                     "URL must have a fragment containing ctx")
        XCTAssertTrue(fragment.hasPrefix("ctx="),
                      "Fragment must start with `ctx=`; got `\(fragment)`")

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

    func testBuildEnrichedCheckoutURL_appendsHeliumIosBundleIdQueryParam() async throws {
        Helium.lastApiKeyUsed = "test_api_key_for_bundle_id"
        defer { Helium.lastApiKeyUsed = nil }

        let provider: PaymentProviderConfig = .paddle
        let entitlements = HeliumPaymentEntitlementsSource(provider: provider)
        let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: entitlements)

        let baseURL = URL(string: "https://bundles-staging.heliumpaywall.com/o/p/bundle.html")!
        let templateEvent = PurchaseSucceededEvent(
            productId: "", triggerName: "t", paywallName: "P",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.kind
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

        let bundleIdItem = try XCTUnwrap(
            items.first(where: { $0.name == "helium_ios_bundle_id" }),
            "Expected helium_ios_bundle_id query param; got \(items.map { $0.name })"
        )
        let bundleIdValue = try XCTUnwrap(bundleIdItem.value)
        XCTAssertFalse(bundleIdValue.isEmpty, "helium_ios_bundle_id value must not be empty")
        XCTAssertEqual(bundleIdValue, Bundle.main.bundleIdentifier ?? "unknown")

        let fragment = try XCTUnwrap(components.fragment)
        XCTAssertTrue(fragment.hasPrefix("ctx="))
    }

    func testBuildEnrichedCheckoutURL_doesNotDoubleWriteHeliumIosBundleId() async throws {
        Helium.lastApiKeyUsed = "test_api_key_for_bundle_id_idempotent"
        defer { Helium.lastApiKeyUsed = nil }

        let provider: PaymentProviderConfig = .paddle
        let entitlements = HeliumPaymentEntitlementsSource(provider: provider)
        let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: entitlements)

        let baseURL = URL(string: "https://bundles-staging.heliumpaywall.com/o/p/bundle.html?helium_ios_bundle_id=com.preset.app")!
        let templateEvent = PurchaseSucceededEvent(
            productId: "", triggerName: "t", paywallName: "P",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.kind
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

        let matches = items.filter { $0.name == "helium_ios_bundle_id" }
        XCTAssertEqual(matches.count, 1, "Must not double-write helium_ios_bundle_id; got \(matches.map { $0.value ?? "nil" })")
        XCTAssertEqual(matches.first?.value, "com.preset.app")
    }

    // MARK: - End-to-end

    func testBuildEnrichedCheckoutURL_emitsCompressedCtxAsBase64URL() async throws {
        Helium.lastApiKeyUsed = "test_api_key_for_compression"
        defer { Helium.lastApiKeyUsed = nil }

        let provider: PaymentProviderConfig = .paddle
        let entitlements = HeliumPaymentEntitlementsSource(provider: provider)
        let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: entitlements)

        let baseURL = URL(string: "https://bundles-staging.heliumpaywall.com/org/paywall/bundle.html")!
        let templateEvent = PurchaseSucceededEvent(
            productId: "",
            triggerName: "test_trigger",
            paywallName: "Test Paywall",
            storeKitTransactionId: nil,
            storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.kind
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

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let fragment = try XCTUnwrap(components.fragment, "URL must have a ctx fragment")
        XCTAssertTrue(fragment.hasPrefix("ctx="),
                      "Fragment must start with `ctx=`; got `\(fragment)`")
        let ctxValue = String(fragment.dropFirst("ctx=".count))

        let compressed = try XCTUnwrap(base64URLDecode(ctxValue),
                                       "ctx value isn't valid base64URL")

        let decompressed = try decompressWithAppleZlib(compressed, originalSize: 8192)

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
            paymentProcessor: provider.kind
        )
        let analyticsEvent = HeliumAnalyticsManager.shared.buildLoggedEvent(
            for: templateEvent,
            paywallSession: PaywallSession(trigger: "t", paywallInfo: nil, fallbackType: .notFallback, presentationContext: .empty)
        )

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

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let fragment = try XCTUnwrap(components.fragment, "URL must have a ctx fragment")
        XCTAssertTrue(fragment.hasPrefix("ctx="), "Fragment must start with `ctx=`; got `\(fragment)`")
        let ctxValue = String(fragment.dropFirst("ctx=".count))
        let compressedB64Length = ctxValue.count

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
            paymentProcessor: provider.kind
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

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let fragment = try XCTUnwrap(components.fragment, "URL must have a ctx fragment")
        XCTAssertTrue(fragment.hasPrefix("ctx="), "Fragment must start with `ctx=`; got `\(fragment)`")
        let ctxValue = String(fragment.dropFirst("ctx=".count))
        let compressed = try XCTUnwrap(base64URLDecode(ctxValue))
        let decompressed = try decompressWithAppleZlib(compressed, originalSize: 16_384)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: decompressed) as? [String: Any])

        let entitledMap = try XCTUnwrap(parsed["paddleAlreadyEntitled"] as? [String: Any])
        let yearlyEntry = try XCTUnwrap(entitledMap["pri_yearly"] as? [String: Any])
        XCTAssertEqual(yearlyEntry["code"] as? String, "duplicate_subscription")
        XCTAssertEqual(yearlyEntry["message"] as? String, "You already own yearly")
    }

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
            paymentProcessor: provider.kind
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

    // MARK: - stripeIntroOfferEligibleByProduct map round-trips through ctx

    func testBuildEnrichedCheckoutURL_includesStripeIntroOfferEligibleByProductWhenProvided() async throws {
        Helium.lastApiKeyUsed = "test_api_key_for_compression"
        defer { Helium.lastApiKeyUsed = nil }

        let provider: PaymentProviderConfig = .stripe
        let entitlements = HeliumPaymentEntitlementsSource(provider: provider)
        let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: entitlements)

        let baseURL = URL(string: "https://bundles-staging.heliumpaywall.com/o/p/bundle.html")!
        let templateEvent = PurchaseSucceededEvent(
            productId: "", triggerName: "t", paywallName: "P",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.kind
        )
        let analyticsEvent = HeliumAnalyticsManager.shared.buildLoggedEvent(
            for: templateEvent,
            paywallSession: PaywallSession(trigger: "t", paywallInfo: nil, fallbackType: .notFallback, presentationContext: .empty)
        )

        let eligibleByProduct: [String: Bool] = [
            "prod_a:pri_yearly": true,
            "prod_b:pri_monthly": false,
        ]

        let url = try manager.buildEnrichedCheckoutURL(
            baseURL: baseURL, analyticsEvent: analyticsEvent,
            productKey: "prod_a:pri_yearly", triggerName: "t",
            successURL: "ok", cancelURL: "no",
            introOfferEligible: true,
            paddleBootstraps: nil,
            paddleAlreadyEntitled: nil,
            stripeIntroOfferEligibleByProduct: eligibleByProduct
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let fragment = try XCTUnwrap(components.fragment, "URL must have a ctx fragment")
        XCTAssertTrue(fragment.hasPrefix("ctx="), "Fragment must start with `ctx=`; got `\(fragment)`")
        let ctxValue = String(fragment.dropFirst("ctx=".count))
        let compressed = try XCTUnwrap(base64URLDecode(ctxValue))
        let decompressed = try decompressWithAppleZlib(compressed, originalSize: 16_384)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: decompressed) as? [String: Any])

        let eligibleMap = try XCTUnwrap(parsed["stripeIntroOfferEligibleByProduct"] as? [String: Any])
        XCTAssertEqual(eligibleMap["prod_a:pri_yearly"] as? Bool, true)
        XCTAssertEqual(eligibleMap["prod_b:pri_monthly"] as? Bool, false)
        // Coarse bool stays as the safety-net signal for older bundles.
        XCTAssertEqual(parsed["introOfferEligible"] as? Bool, true)
    }

    func testBuildEnrichedCheckoutURL_omitsStripeIntroOfferEligibleByProductWhenNil() async throws {
        Helium.lastApiKeyUsed = "test_api_key_for_compression"
        defer { Helium.lastApiKeyUsed = nil }

        let provider: PaymentProviderConfig = .stripe
        let entitlements = HeliumPaymentEntitlementsSource(provider: provider)
        let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: entitlements)

        let baseURL = URL(string: "https://bundles-staging.heliumpaywall.com/o/p/bundle.html")!
        let templateEvent = PurchaseSucceededEvent(
            productId: "", triggerName: "t", paywallName: "P",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.kind
        )
        let analyticsEvent = HeliumAnalyticsManager.shared.buildLoggedEvent(
            for: templateEvent,
            paywallSession: PaywallSession(trigger: "t", paywallInfo: nil, fallbackType: .notFallback, presentationContext: .empty)
        )

        let url = try manager.buildEnrichedCheckoutURL(
            baseURL: baseURL, analyticsEvent: analyticsEvent,
            productKey: "prod_a:pri_yearly", triggerName: "t",
            successURL: "ok", cancelURL: "no",
            introOfferEligible: true,
            paddleBootstraps: nil,
            paddleAlreadyEntitled: nil,
            stripeIntroOfferEligibleByProduct: nil
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let fragment = try XCTUnwrap(components.fragment, "URL must have a ctx fragment")
        XCTAssertTrue(fragment.hasPrefix("ctx="), "Fragment must start with `ctx=`; got `\(fragment)`")
        let ctxValue = String(fragment.dropFirst("ctx=".count))
        let compressed = try XCTUnwrap(base64URLDecode(ctxValue))
        let decompressed = try decompressWithAppleZlib(compressed, originalSize: 8_192)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: decompressed) as? [String: Any])

        XCTAssertNil(parsed["stripeIntroOfferEligibleByProduct"], "Omitted when caller passes nil")
    }

    // MARK: - Larger realistic payload (regression test)

    func testDeflateRaw_roundTripsLargeRealisticPaywallCtx() throws {
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

        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: decompressed),
                         "Decompressed payload must parse back to JSON")
    }

    // MARK: - Empty / edge-case inputs

    func testDeflateRaw_handlesEmptyInput() throws {
        let empty = Data()
        let compressed = CtxCompression.deflateRaw(empty)

        // Accept nil or a small Data (DEFLATE empty-stream marker); must not crash.
        if let compressed = compressed {
            let decompressed = try decompressWithAppleZlib(compressed, originalSize: 0)
            XCTAssertEqual(decompressed, empty)
        }
    }

    // MARK: - Helpers

    private func base64URLDecode(_ encoded: String) -> Data? {
        var s = encoded.replacingOccurrences(of: "-", with: "+")
                       .replacingOccurrences(of: "_", with: "/")
        let padNeeded = (4 - (s.count % 4)) % 4
        s += String(repeating: "=", count: padNeeded)
        return Data(base64Encoded: s)
    }

    private func decompressWithAppleZlib(_ data: Data, originalSize: Int) throws -> Data {
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
