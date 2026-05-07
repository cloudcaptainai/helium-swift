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
        } catch let PaddlePrefetchError.alreadyEntitled(code, message) {
            XCTAssertEqual(code, "duplicate_subscription")
            XCTAssertTrue(
                message.contains("already have an active subscription"),
                "Expected detail message to be preserved on alreadyEntitled error; got \(message)"
            )
        } catch {
            XCTFail("Expected PaddlePrefetchError.alreadyEntitled but got \(type(of: error)): \(error)")
        }
    }

    /// 409s with a different error code (anything that isn't
    /// `duplicate_subscription`) should pass through as a generic server
    /// error. Specific to alreadyEntitled is the right granularity — we
    /// don't want every 409 to look like an entitlement match.
    func testCreatePaddleTransactionForPaywall_otherNon409CodesPassThroughAsServerError() async throws {
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
            XCTFail("Expected createPaddleTransactionForPaywall to throw on 409")
        } catch HeliumPaymentAPIError.serverError(let statusCode, let message) {
            XCTAssertEqual(statusCode, 409)
            XCTAssertTrue(
                message.contains("trial_already_used"),
                "Expected non-duplicate 409 to surface as serverError preserving the code in the message; got \(message)"
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
