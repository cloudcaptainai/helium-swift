import XCTest
@testable import Helium

/// Tests for the Paddle checkout-prefetch client methods on
/// HeliumPaymentAPIClient. These methods sit on the SDK pre-fetch path
/// (HEL-5326): the SDK calls bandit's /paddle/create-transaction-for-paywall
/// during paywall presentation so the bundle in Safari can skip its own
/// pre-warm.
///
/// Network is intercepted via MockURLProtocol so tests are fast and offline.
final class PaddleCheckoutPrefetchClientTests: XCTestCase {

    private var session: URLSession!
    private var client: HeliumPaymentAPIClient!

    override func setUp() {
        super.setUp()

        // URLSession with our test interceptor in front of every request.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        client = HeliumPaymentAPIClient(urlSession: session)

        // baseRequestBody requires Helium.lastApiKeyUsed to be set; otherwise
        // it throws .notInitialized. Stub it for tests since we don't run
        // through the full Helium.initialize() flow here.
        Helium.lastApiKeyUsed = "test_api_key_for_prefetch_tests"

        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        Helium.lastApiKeyUsed = nil
        super.tearDown()
    }

    // MARK: - createPaddleTransactionForPaywall — success path

    func testCreatePaddleTransactionForPaywall_decodesSuccessResponse() async throws {
        // Mirror the bandit's PaddleCreateTransactionForPaywallResponse shape.
        let bodyJSON = """
        {
            "transactionId": "txn_01knspnrb3drka149qnaceps9a",
            "paddleCustomerId": "ctm_01k77z6m9t3rs0aw23h9gpv61e",
            "isKnownCustomer": true,
            "requestId": "req_test_xyz"
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, bodyJSON.data(using: .utf8)!)
        }

        let result = try await client.createPaddleTransactionForPaywall(priceId: "pri_01km39t4kt3rs0aw23h9gpv61e")

        XCTAssertEqual(result.transactionId, "txn_01knspnrb3drka149qnaceps9a")
        XCTAssertEqual(result.paddleCustomerId, "ctm_01k77z6m9t3rs0aw23h9gpv61e")
        XCTAssertTrue(result.isKnownCustomer)
        XCTAssertEqual(result.requestId, "req_test_xyz")
    }

    func testCreatePaddleTransactionForPaywall_paddleCustomerIdOptionalForUnknownCustomer() async throws {
        // Bandit omits paddleCustomerId for unknown customers (omitempty in Go).
        // Codable must treat that as nil, not crash.
        let bodyJSON = """
        {
            "transactionId": "txn_unknown",
            "isKnownCustomer": false,
            "requestId": "req_unknown"
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, bodyJSON.data(using: .utf8)!)
        }

        let result = try await client.createPaddleTransactionForPaywall(priceId: "pri_xyz")

        XCTAssertEqual(result.transactionId, "txn_unknown")
        XCTAssertNil(result.paddleCustomerId)
        XCTAssertFalse(result.isKnownCustomer)
    }

    // MARK: - createPaddleTransactionForPaywall — request shape

    // MARK: - createPaddleTransactionForPaywall — 409 alreadyEntitled handling

    /// When bandit returns 409 with `code: "duplicate_subscription"`, the
    /// customer already owns this product. The SDK pre-fetch path needs to
    /// detect this so the caller (PaddleCheckoutPrefetch coordinator) can
    /// resolve the flow as `preCheckResolved` instead of opening the
    /// browser to a guaranteed-failure UX (HEL-5326, Option A).
    func testCreatePaddleTransactionForPaywall_throwsAlreadyEntitledOn409DuplicateSubscription() async throws {
        let envelope = """
        {
            "error": {
                "type": "request_error",
                "code": "duplicate_subscription",
                "detail": "You already have an active subscription for this product"
            },
            "meta": { "requestId": "req_dup_001" }
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected createPaddleTransactionForPaywall to throw on 409 duplicate_subscription")
        } catch let PaddlePrefetchError.alreadyEntitled(code, message, existingSubscriptionId) {
            XCTAssertEqual(code, "duplicate_subscription")
            XCTAssertTrue(
                message.contains("already have an active subscription"),
                "Expected detail message to be preserved on alreadyEntitled error; got \(message)"
            )
            // No subscription_id in this body → field absent.
            XCTAssertNil(existingSubscriptionId)
        } catch {
            XCTFail("Expected PaddlePrefetchError.alreadyEntitled but got \(type(of: error)): \(error)")
        }
    }

    // MARK: - existingSubscriptionId extraction (Gap 2)

    /// When bandit's 409 body carries the buyer's existing subscription
    /// id, the SDK must thread it through `PaddlePrefetchError.alreadyEntitled`
    /// so it can land in `ctx.paddleAlreadyEntitled` and ultimately become
    /// `canonicalJoinTransactionId` in the bundle's `helium_purchase_already_entitled`
    /// Jitsu fire. Five lookup paths are accepted (mirrors the bundler's
    /// `parsePaddle409`):
    ///   1. error.subscription_id (Paddle's canonical snake_case)
    ///   2. error.subscriptionId
    ///   3. error.meta.subscription_id
    ///   4. subscription_id (top-level)
    ///   5. subscriptionId (top-level)
    func testCreatePaddleTransactionForPaywall_extractsExistingSubscriptionId_fromErrorSubscriptionId() async throws {
        let envelope = """
        {
            "error": {
                "code": "duplicate_subscription",
                "detail": "x",
                "subscription_id": "sub_01k_path1"
            }
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected to throw")
        } catch let PaddlePrefetchError.alreadyEntitled(_, _, existingSubscriptionId) {
            XCTAssertEqual(existingSubscriptionId, "sub_01k_path1")
        }
    }

    func testCreatePaddleTransactionForPaywall_extractsExistingSubscriptionId_fromErrorSubscriptionIdCamelCase() async throws {
        let envelope = """
        {
            "error": {
                "code": "duplicate_subscription",
                "detail": "x",
                "subscriptionId": "sub_01k_path2"
            }
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected to throw")
        } catch let PaddlePrefetchError.alreadyEntitled(_, _, existingSubscriptionId) {
            XCTAssertEqual(existingSubscriptionId, "sub_01k_path2")
        }
    }

    func testCreatePaddleTransactionForPaywall_extractsExistingSubscriptionId_fromErrorMeta() async throws {
        let envelope = """
        {
            "error": {
                "code": "duplicate_subscription",
                "detail": "x",
                "meta": { "subscription_id": "sub_01k_path3" }
            }
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected to throw")
        } catch let PaddlePrefetchError.alreadyEntitled(_, _, existingSubscriptionId) {
            XCTAssertEqual(existingSubscriptionId, "sub_01k_path3")
        }
    }

    func testCreatePaddleTransactionForPaywall_extractsExistingSubscriptionId_fromTopLevelSnakeCase() async throws {
        let envelope = """
        {
            "error": { "code": "duplicate_subscription", "detail": "x" },
            "subscription_id": "sub_01k_path4"
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected to throw")
        } catch let PaddlePrefetchError.alreadyEntitled(_, _, existingSubscriptionId) {
            XCTAssertEqual(existingSubscriptionId, "sub_01k_path4")
        }
    }

    func testCreatePaddleTransactionForPaywall_extractsExistingSubscriptionId_fromTopLevelCamelCase() async throws {
        let envelope = """
        {
            "error": { "code": "duplicate_subscription", "detail": "x" },
            "subscriptionId": "sub_01k_path5"
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected to throw")
        } catch let PaddlePrefetchError.alreadyEntitled(_, _, existingSubscriptionId) {
            XCTAssertEqual(existingSubscriptionId, "sub_01k_path5")
        }
    }

    /// First-non-empty-wins: when multiple paths are present, the
    /// most-specific one wins. error.subscription_id beats top-level.
    func testCreatePaddleTransactionForPaywall_existingSubscriptionId_prefersMoreSpecificPath() async throws {
        let envelope = """
        {
            "error": {
                "code": "duplicate_subscription",
                "detail": "x",
                "subscription_id": "sub_specific"
            },
            "subscription_id": "sub_top_level_should_lose"
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected to throw")
        } catch let PaddlePrefetchError.alreadyEntitled(_, _, existingSubscriptionId) {
            XCTAssertEqual(existingSubscriptionId, "sub_specific")
        }
    }

    /// 409 with `code: "trial_already_used"` is also surfaced as
    /// `PaddlePrefetchError.alreadyEntitled` (with the original code
    /// preserved). Bundle's `routePaddle409` then maps to entitled_failure
    /// at click-time; SDK's tappedShortCircuit refuses to fire restored
    /// for non-restorable codes — see `is409CodeRestorable`. The
    /// motivation: catching this 409 in pre-fetch means the bundle can
    /// short-circuit without a live bandit call, same as for
    /// duplicate_subscription. UX downstream is what differs: the
    /// bundle redirects to paymentFailureUrl (not successUrl).
    func testCreatePaddleTransactionForPaywall_throwsAlreadyEntitledOn409TrialAlreadyUsed() async throws {
        let envelope = """
        {
            "error": {
                "type": "request_error",
                "code": "trial_already_used",
                "detail": "Customer has already consumed a trial on a different product"
            }
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected createPaddleTransactionForPaywall to throw on 409 trial_already_used")
        } catch let PaddlePrefetchError.alreadyEntitled(code, message, _) {
            // Code is preserved verbatim — bundle's routePaddle409 reads
            // the code at click-time to decide success vs failure routing.
            XCTAssertEqual(code, "trial_already_used")
            XCTAssertTrue(message.contains("Customer has already consumed a trial"))
        } catch {
            XCTFail("Expected PaddlePrefetchError.alreadyEntitled but got \(type(of: error)): \(error)")
        }
    }

    /// 409 with an unknown code (one neither `duplicate_subscription`
    /// nor `trial_already_used`) still passes through as a generic
    /// server error. The allow-list is explicit — adding a new code
    /// should be a deliberate decision matching the bundle's
    /// `routePaddle409`.
    func testCreatePaddleTransactionForPaywall_unknownNon409CodePassesThroughAsServerError() async throws {
        let envelope = """
        {
            "error": {
                "type": "request_error",
                "code": "some_future_paddle_code",
                "detail": "Hypothetical new failure mode"
            }
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected createPaddleTransactionForPaywall to throw on 409")
        } catch HeliumPaymentAPIError.serverError(let statusCode, let message) {
            XCTAssertEqual(statusCode, 409)
            XCTAssertTrue(
                message.contains("some_future_paddle_code"),
                "Expected unknown 409 code to surface as serverError preserving the code in the message; got \(message)"
            )
        } catch {
            XCTFail("Expected HeliumPaymentAPIError.serverError but got \(type(of: error)): \(error)")
        }
    }

    // MARK: - createPaddleTransactionForPaywall — request shape

    /// The bandit's PaddleCreateTransactionForPaywallRequest is strict about
    /// field names — it validates `priceId` as required. The Stripe path
    /// uses `productPriceId` (a "product_id:price_id" composite), but
    /// Paddle's bandit handler expects just `priceId` ("pri_xxx"). Earlier
    /// versions of this client routed through `baseRequestBody(productId:)`
    /// which produces `productPriceId` — wrong for Paddle. This test locks
    /// in the correct wire contract so we don't regress.
    func testCreatePaddleTransactionForPaywall_sendsCorrectBanditContract() async throws {
        let bodyJSON = """
        {"transactionId": "txn_x", "isKnownCustomer": false, "requestId": "req_x"}
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, bodyJSON.data(using: .utf8)!)
        }

        _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_specific_price")

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        let captured = MockURLProtocol.capturedRequests[0]
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertTrue(
            captured.url?.path.hasSuffix("/paddle/create-transaction-for-paywall") ?? false,
            "Expected URL path to end with /paddle/create-transaction-for-paywall, got \(captured.url?.absoluteString ?? "nil")"
        )

        let bodyData = captured.httpBody ?? Data()
        let bodyDict = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        // Required by bandit's request validator (PaddleCreateTransactionForPaywallRequest):
        XCTAssertEqual(
            bodyDict["priceId"] as? String,
            "pri_specific_price",
            "Bandit's Paddle handler validates `priceId` as required (json:\"priceId\" validate:\"required\"). " +
            "If this asserts `productPriceId`, the SDK is sending the Stripe-shaped composite key instead of the bare priceId Paddle expects, and bandit will reject the request with a 400."
        )
        XCTAssertEqual(bodyDict["apiKey"] as? String, "test_api_key_for_prefetch_tests")

        // Should NOT carry the Stripe composite-key field on the Paddle path —
        // it's at best ignored (bandit's request struct doesn't decode it),
        // at worst confusing in server logs.
        XCTAssertNil(
            bodyDict["productPriceId"],
            "`productPriceId` is the Stripe-path field name; Paddle should not send it."
        )

        // Identity fields the SDK can populate from local state:
        XCTAssertEqual(bodyDict["heliumPersistentId"] as? String, HeliumIdentityManager.shared.getHeliumPersistentId())
    }
}
