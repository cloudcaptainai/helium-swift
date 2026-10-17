import XCTest
@testable import Helium

@MainActor
final class PaddleCheckoutPrefetchCoordinatorTests: XCTestCase {

    private var testSession: PaywallSession!
    private var testSessionId: String { testSession.sessionId }

    private var session: URLSession!
    private var banditClient: HeliumPaymentAPIClient!
    private var bffClient: PaddleBFFClient!
    private var coordinator: PaddleCheckoutPrefetchCoordinator!

    override func setUp() {
        super.setUp()

        testSession = makeTestSession()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        banditClient = HeliumPaymentAPIClient(urlSession: session)
        bffClient = PaddleBFFClient(urlSession: session)
        coordinator = PaddleCheckoutPrefetchCoordinator(
            banditClient: banditClient,
            bffClient: bffClient
        )

        Helium.lastApiKeyUsed = "test_api_key_for_coordinator"
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        // Wait for in-flight prefetches to stop before resetting MockURLProtocol's
        // static state to avoid flaky cross-test request capture.
        await coordinator.cancelAllAndAwait()
        MockURLProtocol.reset()
        HeliumFetchedConfigManager.reset()
        Helium.lastApiKeyUsed = nil
        try await super.tearDown()
    }

    // MARK: - Response stubs

    private func banditSuccessBody(transactionId: String, knownCustomer: Bool = true) -> String {
        return """
        {
            "transactionId": "\(transactionId)",
            "paddleCustomerId": "ctm_test",
            "isKnownCustomer": \(knownCustomer),
            "requestId": "req_\(transactionId)"
        }
        """
    }

    private func banditDuplicateBody() -> String {
        return """
        {
            "error": {
                "type": "request_error",
                "code": "duplicate_subscription",
                "detail": "You already have an active subscription for this product"
            }
        }
        """
    }

    private func bffSuccessBody(checkoutId: String, transactionId: String) -> String {
        return """
        {
            "data": {
                "id": "\(checkoutId)",
                "transaction_id": "\(transactionId)",
                "status": "draft"
            }
        }
        """
    }

    private func makeBandit(transactionId: String = "txn_x") -> PaddleCreateTransactionForPaywallResponse {
        return PaddleCreateTransactionForPaywallResponse(
            transactionId: transactionId,
            paddleCustomerId: nil,
            isKnownCustomer: false,
            requestId: "req_x"
        )
    }

    private func makePaddle() -> PaddleTransactionCheckoutResult {
        return PaddleTransactionCheckoutResult(
            rawBody: "{}".data(using: .utf8)!,
            checkoutId: "che_x",
            transactionId: "txn_x"
        )
    }

    private func bothSucceedHandler() -> ((URLRequest) throws -> (HTTPURLResponse, Data?)) {
        return { request in
            let url = request.url!.absoluteString
            if url.contains("/paddle/create-transaction-for-paywall") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, self.banditSuccessBody(transactionId: "txn_for_pri_x").data(using: .utf8)!)
            } else if url.contains("/transaction-checkout") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, self.bffSuccessBody(checkoutId: "che_session_x", transactionId: "txn_for_pri_x").data(using: .utf8)!)
            }
            throw NSError(domain: "PaddleCheckoutPrefetchCoordinatorTests", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected URL: \(url)"])
        }
    }

    // MARK: - Happy path

    func testAwaitOutcome_returnsReady_whenBothCallsSucceed() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        coordinator.prefetch(
            paywallSession: testSession,
            priceIds: ["pri_x"],
            paddleClientToken: "test_xyz",
            iosBundleId: "com.example.test"
        )

        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_x")

        guard case .ready(let bandit, let paddle) = outcome else {
            XCTFail("Expected .ready, got \(outcome)")
            return
        }
        XCTAssertEqual(bandit.transactionId, "txn_for_pri_x")
        XCTAssertEqual(bandit.paddleCustomerId, "ctm_test")
        XCTAssertTrue(bandit.isKnownCustomer)
        XCTAssertEqual(paddle.checkoutId, "che_session_x")
        XCTAssertEqual(paddle.transactionId, "txn_for_pri_x")
        XCTAssertGreaterThan(paddle.rawBody.count, 0)
    }

    /// With the consent modal enabled, a CA-range ip_geo postal resolves
    /// `.ready` and the postal survives into the bundle ctx bootstrap.
    func testAwaitOutcome_returnsReady_whenBFFReportsCaliforniaPostal() async throws {
        HeliumFetchedConfigManager.shared.setFeatureFlagsForTesting(JSON(["caConsentModalEnabled": true]))
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains("/paddle/create-transaction-for-paywall") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, self.banditSuccessBody(transactionId: "txn_ca").data(using: .utf8)!)
            } else if url.contains("/transaction-checkout") {
                let body = """
                {
                    "data": {
                        "id": "che_ca",
                        "transaction_id": "txn_ca",
                        "status": "draft",
                        "ip_geo_country_code": "US",
                        "ip_geo_postal_code": "90210"
                    }
                }
                """
                let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, body.data(using: .utf8)!)
            }
            throw NSError(domain: "test", code: 0)
        }

        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_ca"], paddleClientToken: "test_xyz", iosBundleId: nil)
        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_ca")

        guard case .ready(_, let paddle) = outcome else {
            XCTFail("California buyers must resolve .ready when the consent modal is enabled; got \(outcome)")
            return
        }
        XCTAssertEqual(paddle.checkoutId, "che_ca")
        let map = try XCTUnwrap(
            PaddleCheckoutPrefetchCoordinator.encodeBootstrapsToCtx(outcomesByPriceId: ["pri_ca": outcome])
        )
        let data = try XCTUnwrap(
            ((map["pri_ca"] as? [String: Any])?["paddleCheckoutResponse"] as? [String: Any])?["data"] as? [String: Any]
        )
        XCTAssertEqual(data["ip_geo_postal_code"] as? String, "90210")
    }

    // MARK: - California ip_geo block

    func testAwaitOutcome_blocksCaliforniaPostal_whenModalFlagOff() async throws {
        // caConsentModalEnabled defaults off, so a CA ip_geo postal is blocked.
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains("/paddle/create-transaction-for-paywall") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, self.banditSuccessBody(transactionId: "txn_ca").data(using: .utf8)!)
            } else if url.contains("/transaction-checkout") {
                let body = """
                { "data": { "id": "che_ca", "transaction_id": "txn_ca", "status": "draft", "ip_geo_country_code": "US", "ip_geo_postal_code": "90210" } }
                """
                let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, body.data(using: .utf8)!)
            }
            throw NSError(domain: "test", code: 0)
        }

        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_ca"], paddleClientToken: "test_xyz", iosBundleId: nil)
        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_ca")

        guard case .failed(let error) = outcome else {
            XCTFail("CA buyer must be blocked when the consent modal is off; got \(outcome)")
            return
        }
        let caError = try XCTUnwrap(error as? PaddleCaliforniaBlocked)
        XCTAssertEqual(caError.postalCode, "90210")
    }

    func testAwaitOutcome_doesNotBlock_whenNonCaliforniaPostal_andFlagOff() async throws {
        // Flag off, but a non-CA ip_geo postal is never blocked.
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains("/paddle/create-transaction-for-paywall") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, self.banditSuccessBody(transactionId: "txn_ny").data(using: .utf8)!)
            } else if url.contains("/transaction-checkout") {
                let body = """
                { "data": { "id": "che_ny", "transaction_id": "txn_ny", "status": "draft", "ip_geo_country_code": "US", "ip_geo_postal_code": "10001" } }
                """
                let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, body.data(using: .utf8)!)
            }
            throw NSError(domain: "test", code: 0)
        }

        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_ny"], paddleClientToken: "test_xyz", iosBundleId: nil)
        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_ny")

        guard case .ready = outcome else {
            XCTFail("non-California buyer must resolve .ready; got \(outcome)")
            return
        }
    }

    // MARK: - alreadyEntitled

    func testAwaitOutcome_returnsAlreadyEntitled_whenBanditReturns409Duplicate_andSkipsBFFCall() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains("/paddle/create-transaction-for-paywall") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
                return (response, self.banditDuplicateBody().data(using: .utf8)!)
            }
            throw NSError(domain: "test", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "BFF was called after bandit 409 — should have short-circuited"])
        }

        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)
        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_x")

        guard case .alreadyEntitled(let code, let message, _) = outcome else {
            XCTFail("Expected .alreadyEntitled, got \(outcome)")
            return
        }
        XCTAssertEqual(code, "duplicate_subscription")
        XCTAssertTrue(message.contains("already have an active subscription"))

        let bffCalls = MockURLProtocol.capturedRequests.filter {
            ($0.url?.absoluteString ?? "").contains("/transaction-checkout")
        }
        XCTAssertEqual(bffCalls.count, 0, "BFF should not be called when bandit returns 409 duplicate_subscription")
    }

    // MARK: - failed paths

    func testAwaitOutcome_returnsFailed_whenBanditReturns500() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains("/paddle/create-transaction-for-paywall") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, "{\"error\":{\"code\":\"internal\"}}".data(using: .utf8)!)
            }
            throw NSError(domain: "test", code: 0)
        }

        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)
        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_x")

        guard case .failed = outcome else {
            XCTFail("Expected .failed, got \(outcome)")
            return
        }
    }

    func testAwaitOutcome_returnsFailed_whenBFFReturns401() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains("/paddle/create-transaction-for-paywall") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, self.banditSuccessBody(transactionId: "txn_x").data(using: .utf8)!)
            } else if url.contains("/transaction-checkout") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (response, "{\"errors\":[{\"code\":\"unauthorized\"}]}".data(using: .utf8)!)
            }
            throw NSError(domain: "test", code: 0)
        }

        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)
        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_x")

        guard case .failed = outcome else {
            XCTFail("Expected .failed, got \(outcome)")
            return
        }
    }

    // MARK: - cache misses

    func testAwaitOutcome_returnsNotStarted_whenNoPrefetchWasCalled() async {
        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_unknown")

        guard case .notStarted = outcome else {
            XCTFail("Expected .notStarted for priceId never prefetched, got \(outcome)")
            return
        }
    }

    func testAwaitOutcome_returnsNotStarted_forPriceIdNotInPrefetchSet() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)

        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_y_not_prefetched")

        guard case .notStarted = outcome else {
            XCTFail("Expected .notStarted for priceId outside the prefetched set, got \(outcome)")
            return
        }
    }

    func testAwaitOutcome_returnsNotStarted_whenSessionIdDoesNotMatch() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        let sessionA = makeTestSession()
        let sessionB = makeTestSession()

        coordinator.prefetch(paywallSession: sessionA, priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)

        let outcome = await coordinator.awaitOutcome(sessionId: sessionB.sessionId, priceId: "pri_x")

        guard case .notStarted = outcome else {
            XCTFail("Different session id should be a cache miss; got \(outcome)")
            return
        }
    }

    // MARK: - cancellation

    func testCancelAll_clearsCache_subsequentAwaitsReturnNotStarted() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)
        coordinator.cancelAll()

        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_x")

        guard case .notStarted = outcome else {
            XCTFail("After cancelAll, awaitOutcome should return .notStarted (cache cleared)")
            return
        }
    }

    // MARK: - Timeout on awaitOutcome

    /// Asserts elapsed wall-clock, not just outcome kind — a buggy impl
    /// that waits on the task would still eventually return `.failed`.
    func testAwaitOutcome_timesOut_whenInflightTaskExceedsBudget() async throws {
        MockURLProtocol.requestHandler = { _ in
            Thread.sleep(forTimeInterval: 2.0)
            let response = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_slow"], paddleClientToken: "test_xyz", iosBundleId: nil)

        let start = Date()
        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_slow", timeout: 0.1)
        let elapsed = Date().timeIntervalSince(start)

        guard case .failed = outcome else {
            XCTFail("Expected .failed (timeout) when the in-flight task exceeds the budget; got \(outcome)")
            return
        }

        XCTAssertLessThan(
            elapsed,
            1.0,
            "awaitOutcome with timeout=0.1s should return in well under 1s even if the underlying task hasn't completed; took \(elapsed)s — timeout isn't actually firing"
        )
    }

    func testAwaitOutcome_returnsRealOutcome_whenTaskCompletesWithinBudget() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains("/paddle/create-transaction-for-paywall") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, self.banditSuccessBody(transactionId: "txn_fast").data(using: .utf8)!)
            } else if url.contains("/transaction-checkout") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, self.bffSuccessBody(checkoutId: "che_fast", transactionId: "txn_fast").data(using: .utf8)!)
            }
            throw NSError(domain: "test", code: 0)
        }

        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_fast"], paddleClientToken: "test_xyz", iosBundleId: nil)

        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_fast", timeout: 5.0)

        guard case .ready = outcome else {
            XCTFail("Expected .ready when task completes within timeout; got \(outcome)")
            return
        }
    }

    // MARK: - collectPrefetchOutcomes

    func testCollectPrefetchOutcomes_returnsAllOutcomesForAllPriceIds() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        coordinator.prefetch(
            paywallSession: testSession,
            priceIds: ["pri_a", "pri_b", "pri_c"],
            paddleClientToken: "test_xyz",
            iosBundleId: nil
        )

        let outcomes = await coordinator.collectPrefetchOutcomes(
            sessionId: testSessionId,
            priceIds: ["pri_a", "pri_b", "pri_c"]
        )

        XCTAssertEqual(outcomes.count, 3)
        for priceId in ["pri_a", "pri_b", "pri_c"] {
            guard case .ready = outcomes[priceId] else {
                XCTFail("Expected \(priceId) to be .ready, got \(String(describing: outcomes[priceId]))")
                return
            }
        }
    }

    func testCollectPrefetchOutcomes_handlesEmptyPriceIds() async throws {
        let outcomes = await coordinator.collectPrefetchOutcomes(
            sessionId: testSessionId,
            priceIds: []
        )
        XCTAssertEqual(outcomes.count, 0)
    }

    func testCollectPrefetchOutcomes_handlesSinglePriceId() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        coordinator.prefetch(
            paywallSession: testSession,
            priceIds: ["pri_only"],
            paddleClientToken: "test_xyz",
            iosBundleId: nil
        )

        let outcomes = await coordinator.collectPrefetchOutcomes(
            sessionId: testSessionId,
            priceIds: ["pri_only"]
        )

        XCTAssertEqual(outcomes.count, 1)
        guard case .ready = outcomes["pri_only"] else {
            XCTFail("Expected pri_only to be .ready")
            return
        }
    }

    // MARK: - Per-session cancellation

    func testCancelForSession_removesEntriesOwnedByThatSessionOnly() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        let sessionA = makeTestSession()
        let sessionB = makeTestSession()

        coordinator.prefetch(paywallSession: sessionA, priceIds: ["pri_shared", "pri_a_only"], paddleClientToken: "test_xyz", iosBundleId: nil)
        coordinator.prefetch(paywallSession: sessionB, priceIds: ["pri_shared", "pri_b_only"], paddleClientToken: "test_xyz", iosBundleId: nil)

        coordinator.cancelForSession(sessionId: sessionA.sessionId)

        let aShared = await coordinator.awaitOutcome(sessionId: sessionA.sessionId, priceId: "pri_shared", timeout: 5.0)
        let aOnly = await coordinator.awaitOutcome(sessionId: sessionA.sessionId, priceId: "pri_a_only", timeout: 5.0)
        let bShared = await coordinator.awaitOutcome(sessionId: sessionB.sessionId, priceId: "pri_shared", timeout: 5.0)
        let bOnly = await coordinator.awaitOutcome(sessionId: sessionB.sessionId, priceId: "pri_b_only", timeout: 5.0)

        guard case .notStarted = aShared else {
            XCTFail("session_a/pri_shared should have been wiped by cancelForSession(session_a); got \(aShared)")
            return
        }
        guard case .notStarted = aOnly else {
            XCTFail("session_a/pri_a_only should have been wiped; got \(aOnly)")
            return
        }
        guard case .ready = bShared else {
            XCTFail("session_b/pri_shared should be untouched by cancelForSession(session_a); got \(bShared)")
            return
        }
        guard case .ready = bOnly else {
            XCTFail("session_b/pri_b_only should be untouched; got \(bOnly)")
            return
        }
    }

    // MARK: - Bootstrap encoding for ctx

    private func paddleResponseFixtureWithCruft(
        checkoutId: String = "che_x",
        transactionId: String = "txn_test"
    ) throws -> Data {
        let dict: [String: Any] = [
            "data": [
                "id": checkoutId,
                "transaction_id": transactionId,
                "status": "draft",
                "currency_code": "USD",
                "ip_geo_country_code": "US",
                "ip_geo_postal_code": "94102",
                "consent_required": true,
                "customer": ["id": "ctm_x", "email": "u@e.com"],
                "seller": ["name": "Helium"],
                "items": [
                    [
                        "billing_cycle": ["interval": "month", "frequency": 1],
                        "trial_period": ["interval": "day", "frequency": 7],
                        "price": ["unit_price": ["amount": "499", "currency_code": "USD"]],
                        "id": "txnitm_x",
                        "quantity": ["max_quantity": 999_999, "min_quantity": 1, "current": 1],
                        "totals": ["subtotal": 0, "discount": 0, "tax": 0, "total": 0],
                        "recurring_totals": ["subtotal": 4.99, "total": 4.99],
                        "product": ["id": "pro_x", "name": "Plan", "description": "A plan"],
                        "price_id": "pri_x",
                        "tax_rate": 0,
                    ]
                ],
                "recurring_totals": [
                    "total": 4.99,
                    "subtotal": 4.99, "discount": 0, "credit": 0, "tax": 0, "balance": 4.99,
                ],
                "totals": [
                    "total": 0,
                    "subtotal": 0, "discount": 0, "credit": 0, "tax": 0, "balance": 0,
                ],
                "discount": [
                    "id": "disc_x",
                    "type": "percentage",
                    "amount": "10",
                    "recur": true,
                    "maximum_recurring_intervals": NSNull(),
                ],
                "payments": [
                    "methods_available": [
                        [
                            "type": "PI_APPLE_PAY",
                            "stripe_options": ["api_key": "pk_test_xxx", "country_code": "US"],
                            "weight": 3,
                            "options": ["api_key": "pk_test_xxx", "country_code": "US"],
                            "seller_friendly_name": "apple-pay",
                            "can_be_saved": false,
                            "one_click": true,
                        ],
                        [
                            "type": "CARD",
                            "tokenex_options": ["public_key": "BIG_KEY"],
                            "stripe_options": ["api_key": "pk_test_card", "country_code": "GB"],
                        ],
                        ["type": "PAYPAL", "weight": 2, "options": []],
                    ],
                    "enable_saved_payment_methods": false,
                    "is_payment_processing": false,
                ],
                "settings": [
                    "feature_flags": ["coupon": false, "customer_name": true],
                    "styles": ["theme": "light"],
                    "marketing_consent_message": "Pages of legal text...",
                ],
                "experimentation": [
                    "ld": ["flag1": "value", "flag2": "value", "flag3": "value"],
                    "ab": ["test1": "control", "test2": "control"],
                ],
                "custom_data": ["helium_org_id": "x"],
                "type": "transaction-checkout",
                "is_free": false,
                "environment": "sandbox",
                "created_at": "2026-05-07T02:53:11+00:00",
                "ip_geo_region": "California",
                "source_page": "https://x.com",
                "messages": [],
                "subscription": ["current_billing_period_ends_at": NSNull()],
            ]
        ]
        return try JSONSerialization.data(withJSONObject: dict)
    }

    func testEncodeBootstrapsToCtx_keysMapByPriceId() throws {
        let bandit1 = PaddleCreateTransactionForPaywallResponse(
            transactionId: "txn_a", paddleCustomerId: "ctm_a", isKnownCustomer: true, requestId: "req_a")
        let paddle1 = PaddleTransactionCheckoutResult(
            rawBody: try paddleResponseFixtureWithCruft(checkoutId: "che_a", transactionId: "txn_a"),
            checkoutId: "che_a", transactionId: "txn_a")

        let bandit2 = PaddleCreateTransactionForPaywallResponse(
            transactionId: "txn_b", paddleCustomerId: nil, isKnownCustomer: false, requestId: "req_b")
        let paddle2 = PaddleTransactionCheckoutResult(
            rawBody: try paddleResponseFixtureWithCruft(checkoutId: "che_b", transactionId: "txn_b"),
            checkoutId: "che_b", transactionId: "txn_b")

        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_a": .ready(bandit: bandit1, paddle: paddle1),
            "pri_b": .ready(bandit: bandit2, paddle: paddle2),
        ]

        let map = try XCTUnwrap(PaddleCheckoutPrefetchCoordinator.encodeBootstrapsToCtx(outcomesByPriceId: outcomes))

        XCTAssertEqual(Set(map.keys), ["pri_a", "pri_b"])
        let aBootstrap = try XCTUnwrap(map["pri_a"] as? [String: Any])
        let bBootstrap = try XCTUnwrap(map["pri_b"] as? [String: Any])

        XCTAssertNil(aBootstrap["priceId"], "Inner bootstrap shouldn't repeat priceId — the map key is the priceId")
        XCTAssertEqual((aBootstrap["banditResponse"] as? [String: Any])?["transactionId"] as? String, "txn_a")
        XCTAssertEqual((bBootstrap["banditResponse"] as? [String: Any])?["transactionId"] as? String, "txn_b")
    }

    func testEncodeBootstrapsToCtx_skipsNonReadyOutcomes() throws {
        let bandit = PaddleCreateTransactionForPaywallResponse(
            transactionId: "txn_x", paddleCustomerId: nil, isKnownCustomer: false, requestId: "req_x")
        let paddle = PaddleTransactionCheckoutResult(
            rawBody: try paddleResponseFixtureWithCruft(),
            checkoutId: "che_x", transactionId: "txn_x")

        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_ready": .ready(bandit: bandit, paddle: paddle),
            "pri_entitled": .alreadyEntitled(code: "duplicate_subscription", message: "x", existingSubscriptionId: nil),
            "pri_failed": .failed(error: NSError(domain: "x", code: 0)),
            "pri_notstarted": .notStarted,
        ]

        let map = try XCTUnwrap(PaddleCheckoutPrefetchCoordinator.encodeBootstrapsToCtx(outcomesByPriceId: outcomes))

        XCTAssertEqual(Set(map.keys), ["pri_ready"], "Only .ready outcomes belong in the bootstrap map")
    }

    func testEncodeBootstrapsToCtx_returnsNilWhenNoReadyOutcomes() {
        let allFailed: [String: PaddlePrefetchOutcome] = [
            "pri_a": .failed(error: NSError(domain: "x", code: 0)),
            "pri_b": .notStarted,
        ]
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.encodeBootstrapsToCtx(outcomesByPriceId: allFailed))
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.encodeBootstrapsToCtx(outcomesByPriceId: [:]))
    }

    func testEncodeBootstrapsToCtx_keepsOnlyBundleNeededFieldsInPaddleResponse() throws {
        let bandit = PaddleCreateTransactionForPaywallResponse(
            transactionId: "txn_test", paddleCustomerId: "ctm_x", isKnownCustomer: true, requestId: "req_test")
        let paddle = PaddleTransactionCheckoutResult(
            rawBody: try paddleResponseFixtureWithCruft(),
            checkoutId: "che_x", transactionId: "txn_test")

        let map = try XCTUnwrap(
            PaddleCheckoutPrefetchCoordinator.encodeBootstrapsToCtx(
                outcomesByPriceId: ["pri_x": .ready(bandit: bandit, paddle: paddle)])
        )
        let bootstrap = try XCTUnwrap(map["pri_x"] as? [String: Any])
        let response = try XCTUnwrap(bootstrap["paddleCheckoutResponse"] as? [String: Any])
        let data = try XCTUnwrap(response["data"] as? [String: Any])

        XCTAssertEqual(data["id"] as? String, "che_x")
        XCTAssertEqual(data["transaction_id"] as? String, "txn_test")
        XCTAssertEqual(data["status"] as? String, "draft")
        XCTAssertEqual(data["currency_code"] as? String, "USD")
        XCTAssertEqual(data["ip_geo_country_code"] as? String, "US")
        XCTAssertEqual(data["ip_geo_postal_code"] as? String, "94102")
        XCTAssertEqual(data["created_at"] as? String, "2026-05-07T02:53:11+00:00")
        XCTAssertEqual(data["consent_required"] as? Bool, true)

        let customer = try XCTUnwrap(data["customer"] as? [String: Any])
        XCTAssertEqual(customer["email"] as? String, "u@e.com")

        let seller = try XCTUnwrap(data["seller"] as? [String: Any])
        XCTAssertEqual(seller["name"] as? String, "Helium")

        let items = try XCTUnwrap(data["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        let billing = try XCTUnwrap(item["billing_cycle"] as? [String: Any])
        XCTAssertEqual(billing["interval"] as? String, "month")
        XCTAssertEqual(billing["frequency"] as? Int, 1)
        let trial = try XCTUnwrap(item["trial_period"] as? [String: Any])
        XCTAssertEqual(trial["interval"] as? String, "day")
        XCTAssertEqual(trial["frequency"] as? Int, 7)
        let unitPrice = try XCTUnwrap((item["price"] as? [String: Any])?["unit_price"] as? [String: Any])
        XCTAssertEqual(unitPrice["amount"] as? String, "499")
        XCTAssertEqual(unitPrice["currency_code"] as? String, "USD")

        let recurring = try XCTUnwrap(data["recurring_totals"] as? [String: Any])
        XCTAssertEqual(recurring["total"] as? Double, 4.99)
        let totals = try XCTUnwrap(data["totals"] as? [String: Any])
        XCTAssertEqual(totals["total"] as? Double, 0)

        let discount = try XCTUnwrap(data["discount"] as? [String: Any])
        XCTAssertEqual(discount["id"] as? String, "disc_x")
        XCTAssertEqual(discount["recur"] as? Bool, true)

        let payments = try XCTUnwrap(data["payments"] as? [String: Any])
        let methods = try XCTUnwrap(payments["methods_available"] as? [[String: Any]])
        XCTAssertEqual(methods.count, 1, "Non-Apple-Pay methods must be filtered out")
        XCTAssertEqual(methods[0]["type"] as? String, "PI_APPLE_PAY")
        let stripeOpts = try XCTUnwrap(methods[0]["stripe_options"] as? [String: Any])
        XCTAssertEqual(stripeOpts["api_key"] as? String, "pk_test_xxx")
        XCTAssertEqual(stripeOpts["country_code"] as? String, "US")
    }

    func testEncodeBootstrapsToCtx_dropsLargeUnusedFields() throws {
        let bandit = PaddleCreateTransactionForPaywallResponse(
            transactionId: "txn_x", paddleCustomerId: nil, isKnownCustomer: false, requestId: "req_x")
        let paddle = PaddleTransactionCheckoutResult(
            rawBody: try paddleResponseFixtureWithCruft(),
            checkoutId: "che_x", transactionId: "txn_x")

        let map = try XCTUnwrap(
            PaddleCheckoutPrefetchCoordinator.encodeBootstrapsToCtx(
                outcomesByPriceId: ["pri_x": .ready(bandit: bandit, paddle: paddle)])
        )
        let data = try XCTUnwrap(
            ((map["pri_x"] as? [String: Any])?["paddleCheckoutResponse"] as? [String: Any])?["data"] as? [String: Any]
        )

        for key in [
            "experimentation",
            "settings",
            "custom_data",
            "type", "is_free", "environment",
            "ip_geo_region", "source_page", "messages", "subscription",
        ] {
            XCTAssertNil(data[key], "Field `\(key)` should be dropped by the trim")
        }

        let item = try XCTUnwrap((data["items"] as? [[String: Any]])?.first)
        for key in ["id", "quantity", "totals", "recurring_totals", "product", "price_id", "tax_rate"] {
            XCTAssertNil(item[key], "items[].\(key) should be dropped by the trim")
        }
        let price = try XCTUnwrap(item["price"] as? [String: Any])
        XCTAssertEqual(Set(price.keys), ["unit_price"], "items[].price should only contain unit_price")

        let methods = try XCTUnwrap((data["payments"] as? [String: Any])?["methods_available"] as? [[String: Any]])
        XCTAssertEqual(Set(methods[0].keys), ["type", "stripe_options"],
                       "Apple Pay entry should be trimmed to {type, stripe_options} only")
    }

    // MARK: - Already-entitled encoding for non-tapped products

    func testEncodeAlreadyEntitledToCtx_returnsMapKeyedByPriceId() throws {
        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_yearly": .alreadyEntitled(code: "duplicate_subscription", message: "You already own yearly", existingSubscriptionId: nil),
            "pri_lifetime": .alreadyEntitled(code: "duplicate_subscription", message: "You already own lifetime", existingSubscriptionId: nil),
        ]

        let map = try XCTUnwrap(PaddleCheckoutPrefetchCoordinator.encodeAlreadyEntitledToCtx(outcomesByPriceId: outcomes))

        XCTAssertEqual(Set(map.keys), ["pri_yearly", "pri_lifetime"])
        let yearly = try XCTUnwrap(map["pri_yearly"] as? [String: Any])
        XCTAssertEqual(yearly["code"] as? String, "duplicate_subscription")
        XCTAssertEqual(yearly["message"] as? String, "You already own yearly")
        let lifetime = try XCTUnwrap(map["pri_lifetime"] as? [String: Any])
        XCTAssertEqual(lifetime["message"] as? String, "You already own lifetime")
    }

    func testEncodeAlreadyEntitledToCtx_skipsNonEntitledOutcomes() throws {
        let bandit = makeBandit()
        let paddle = makePaddle()
        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_entitled": .alreadyEntitled(code: "duplicate_subscription", message: "x", existingSubscriptionId: nil),
            "pri_ready": .ready(bandit: bandit, paddle: paddle),
            "pri_failed": .failed(error: NSError(domain: "x", code: 0)),
            "pri_notstarted": .notStarted,
        ]

        let map = try XCTUnwrap(PaddleCheckoutPrefetchCoordinator.encodeAlreadyEntitledToCtx(outcomesByPriceId: outcomes))

        XCTAssertEqual(Set(map.keys), ["pri_entitled"], "Only .alreadyEntitled outcomes belong in the entitled map")
    }

    func testEncodeAlreadyEntitledToCtx_includesExistingSubscriptionIdWhenPresent() throws {
        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_yearly": .alreadyEntitled(
                code: "duplicate_subscription",
                message: "You already own yearly",
                existingSubscriptionId: "sub_01k_abc"
            ),
        ]

        let map = try XCTUnwrap(PaddleCheckoutPrefetchCoordinator.encodeAlreadyEntitledToCtx(outcomesByPriceId: outcomes))

        let yearly = try XCTUnwrap(map["pri_yearly"] as? [String: Any])
        XCTAssertEqual(yearly["existingSubscriptionId"] as? String, "sub_01k_abc")
    }

    func testEncodeAlreadyEntitledToCtx_omitsExistingSubscriptionIdWhenNil() throws {
        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_yearly": .alreadyEntitled(
                code: "duplicate_subscription",
                message: "You already own yearly",
                existingSubscriptionId: nil
            ),
        ]

        let map = try XCTUnwrap(PaddleCheckoutPrefetchCoordinator.encodeAlreadyEntitledToCtx(outcomesByPriceId: outcomes))

        let yearly = try XCTUnwrap(map["pri_yearly"] as? [String: Any])
        XCTAssertNil(yearly["existingSubscriptionId"], "Field absent when SDK didn't extract an id")
    }

    func testEncodeAlreadyEntitledToCtx_returnsNilWhenNoEntitledOutcomes() {
        let allReady: [String: PaddlePrefetchOutcome] = [
            "pri_a": .ready(bandit: makeBandit(), paddle: makePaddle()),
        ]
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.encodeAlreadyEntitledToCtx(outcomesByPriceId: allReady))
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.encodeAlreadyEntitledToCtx(outcomesByPriceId: [:]))
    }

    // MARK: - Tapped-product short-circuit decision

    func testTappedShortCircuit_whenTappedIsAlreadyEntitled_returnsCodeAndMessage() {
        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_tapped": .alreadyEntitled(code: "duplicate_subscription", message: "You already own this", existingSubscriptionId: nil),
            "pri_other": .ready(bandit: makeBandit(), paddle: makePaddle()),
        ]
        let result = PaddleCheckoutPrefetchCoordinator.tappedShortCircuit(
            in: outcomes, tappedPriceId: "pri_tapped"
        )
        XCTAssertEqual(result?.code, "duplicate_subscription")
        XCTAssertEqual(result?.message, "You already own this")
    }

    func testTappedShortCircuit_whenOnlyOtherPriceIdIsAlreadyEntitled_doesNotShortCircuit() {
        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_tapped": .ready(bandit: makeBandit(), paddle: makePaddle()),
            "pri_other": .alreadyEntitled(code: "duplicate_subscription", message: "You own yearly", existingSubscriptionId: nil),
        ]
        let result = PaddleCheckoutPrefetchCoordinator.tappedShortCircuit(
            in: outcomes, tappedPriceId: "pri_tapped"
        )
        XCTAssertNil(result, "Other priceIds being alreadyEntitled must not block the tapped purchase")
    }

    func testTappedShortCircuit_whenTappedIsReady_returnsNil() {
        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_tapped": .ready(bandit: makeBandit(), paddle: makePaddle()),
        ]
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.tappedShortCircuit(
            in: outcomes, tappedPriceId: "pri_tapped"
        ))
    }

    func testTappedShortCircuit_whenTappedIsMissingFromMap_returnsNil() {
        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_other": .alreadyEntitled(code: "duplicate_subscription", message: "x", existingSubscriptionId: nil),
        ]
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.tappedShortCircuit(
            in: outcomes, tappedPriceId: "pri_tapped"
        ))
    }

    /// Only `duplicate_subscription` is restorable; `trial_already_used` is not.
    func testTappedShortCircuit_whenTappedIsTrialAlreadyUsed_returnsNil() {
        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_tapped": .alreadyEntitled(
                code: "trial_already_used",
                message: "You've already used your free trial",
                existingSubscriptionId: nil
            ),
        ]
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.tappedShortCircuit(
            in: outcomes, tappedPriceId: "pri_tapped"
        ),
        "trial_already_used must NOT short-circuit")
    }

    func testTappedShortCircuit_whenTappedIsFailed_returnsNil() {
        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_tapped": .failed(error: NSError(domain: "x", code: 0)),
        ]
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.tappedShortCircuit(
            in: outcomes, tappedPriceId: "pri_tapped"
        ))
    }

    // MARK: - Composite key extraction

    func testExtractPriceIds_extractsPriPrefixedSuffixesFromCompositeKeys() {
        let composites = [
            "pro_01abc:pri_01xyz",
            "pro_01def:pri_01def_yearly",
        ]
        let priceIds = PaddleCheckoutPrefetchCoordinator.extractPriceIds(from: composites)
        XCTAssertEqual(priceIds, ["pri_01xyz", "pri_01def_yearly"])
    }

    func testExtractPriceId_rejectsKeyWithNoColon() {
        XCTAssertNil(
            PaddleCheckoutPrefetchCoordinator.extractPriceId(from: "pri_just_a_priceid"),
            "A key without a colon is not a composite key, even if it starts with `pri_`."
        )
    }

    func testExtractPriceId_rejectsKeyWithMultipleColons() {
        XCTAssertNil(
            PaddleCheckoutPrefetchCoordinator.extractPriceId(from: "pro_x:extra:pri_y")
        )
    }

    func testExtractPriceIds_skipsMalformedCompositeKeys() {
        let composites = [
            "pro_01abc:pri_valid",
            "no_colon_here",
            "pro_01def:NOT_pri_prefixed",
            "",
            ":pri_orphan",
            "pro_x:extra:pri_y",
        ]
        let priceIds = PaddleCheckoutPrefetchCoordinator.extractPriceIds(from: composites)
        XCTAssertEqual(priceIds, ["pri_valid"])
    }

    func testExtractPriceIds_returnsEmptyForEmptyInput() {
        XCTAssertEqual(PaddleCheckoutPrefetchCoordinator.extractPriceIds(from: []), [])
    }

    // MARK: - Parallel prefetch

    func testPrefetch_runsMultiplePriceIdsInParallel() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains("/paddle/create-transaction-for-paywall") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, self.banditSuccessBody(transactionId: "txn_some").data(using: .utf8)!)
            } else if url.contains("/transaction-checkout") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, self.bffSuccessBody(checkoutId: "che_some", transactionId: "txn_some").data(using: .utf8)!)
            }
            throw NSError(domain: "test", code: 0)
        }

        coordinator.prefetch(
            paywallSession: testSession,
            priceIds: ["pri_a", "pri_b"],
            paddleClientToken: "test_xyz",
            iosBundleId: nil
        )

        let outcomeA = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_a")
        let outcomeB = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_b")

        guard case .ready = outcomeA else {
            XCTFail("Expected .ready for pri_a, got \(outcomeA)")
            return
        }
        guard case .ready = outcomeB else {
            XCTFail("Expected .ready for pri_b, got \(outcomeB)")
            return
        }

        let urls = MockURLProtocol.capturedRequests.compactMap { $0.url?.absoluteString }
        let banditCalls = urls.filter { $0.contains("/paddle/create-transaction-for-paywall") }
        let bffCalls = urls.filter { $0.contains("/transaction-checkout") && !$0.contains("/paddle/create-transaction-for-paywall") }
        XCTAssertEqual(banditCalls.count, 2, "Expected 2 bandit calls (one per priceId)")
        XCTAssertEqual(bffCalls.count, 2, "Expected 2 BFF calls (one per priceId)")
    }

    // MARK: - Web second try

    /// Answers each price's prefetch on its own: bandit mints `txn_<priceId>` (or fails it, or
    /// holds it until `release` is signaled), and the BFF response for that transaction can carry
    /// a California ip_geo postal.
    private func perPriceHandler(
        failingBanditPriceIds: Set<String> = [],
        californiaPriceIds: Set<String> = [],
        heldBanditPriceIds: Set<String> = [],
        release: DispatchSemaphore? = nil
    ) -> ((URLRequest) throws -> (HTTPURLResponse, Data?)) {
        return { request in
            let url = request.url!.absoluteString
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if url.contains("/paddle/create-transaction-for-paywall") {
                let priceId = body["priceId"] as? String ?? ""
                if heldBanditPriceIds.contains(priceId) {
                    _ = release?.wait(timeout: .now() + 10)
                }
                if failingBanditPriceIds.contains(priceId) {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                    return (response, Data("{}".utf8))
                }
                let bandit: [String: Any] = [
                    "transactionId": "txn_\(priceId)", "isKnownCustomer": false, "requestId": "req_\(priceId)",
                ]
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, try JSONSerialization.data(withJSONObject: bandit))
            } else if url.contains("/transaction-checkout") {
                let transactionId = (body["data"] as? [String: Any])?["transaction_id"] as? String ?? ""
                var data: [String: Any] = ["id": "che_\(transactionId)", "transaction_id": transactionId, "status": "draft"]
                if californiaPriceIds.contains(where: { "txn_\($0)" == transactionId }) {
                    data["ip_geo_country_code"] = "US"
                    data["ip_geo_postal_code"] = "90210"
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, try JSONSerialization.data(withJSONObject: ["data": data]))
            }
            throw NSError(domain: "PaddleCheckoutPrefetchCoordinatorTests", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected URL: \(url)"])
        }
    }

    private let secondTryInfo = WebSecondTryInfo(
        paywallUUID: "pw-uuid",
        paywallVersionUUID: "pwv-uuid",
        productsOfferedPaddle: ["pro_st:pri_st"]
    )

    private func secondTryPaywallSession(secondTryProducts: [String]) -> PaywallSession {
        var paywallInfo = makeTestPaywallInfo()
        paywallInfo.webProductsOfferedPaddle = ["pro_main:pri_main"]
        paywallInfo.webSecondTry = WebSecondTryInfo(
            paywallUUID: "pw-uuid",
            paywallVersionUUID: "pwv-uuid",
            productsOfferedPaddle: secondTryProducts
        )
        return makeTestSession(paywallInfo: paywallInfo)
    }

    private func injectPaddleConfig(webSecondTryEnabled: Bool) throws {
        var config = makeTestConfig(triggers: [:])
        config.paddleClientToken = "test_xyz"
        config.paddleProducts = [
            "pro_st:pri_st": try JSONDecoder().decode(
                ServerProductPrice.self, from: Data(#"{"defaultDiscountId": "dsc_st"}"#.utf8)
            ),
        ]
        injectConfig(config)
        HeliumFetchedConfigManager.shared.setFeatureFlagsForTesting(JSON(["webSecondTry": webSecondTryEnabled]))
    }

    private func banditRequestBodies() -> [[String: Any]] {
        MockURLProtocol.capturedRequests
            .filter { $0.url?.absoluteString.contains("/paddle/create-transaction-for-paywall") == true }
            .compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }

    func testHandlePaywallOpen_prefetchesTheWebSecondTrysPricesWhileTheFlagIsOn() async throws {
        try injectPaddleConfig(webSecondTryEnabled: true)
        MockURLProtocol.requestHandler = perPriceHandler()
        let session = secondTryPaywallSession(secondTryProducts: ["pro_st:pri_st", "pro_main:pri_main"])

        coordinator.handlePaywallOpen(paywallSession: session)
        let outcomes = await coordinator.collectPrefetchOutcomes(sessionId: session.sessionId, priceIds: ["pri_main", "pri_st"])

        for priceId in ["pri_main", "pri_st"] {
            guard case .ready = outcomes[priceId] else {
                XCTFail("Expected \(priceId) to be .ready, got \(String(describing: outcomes[priceId]))")
                return
            }
        }
        let bodies = banditRequestBodies()
        XCTAssertEqual(
            bodies.compactMap { $0["priceId"] as? String }.sorted(), ["pri_main", "pri_st"],
            "A price both paywalls offer is prefetched once"
        )
        XCTAssertEqual(bodies.first { $0["priceId"] as? String == "pri_st" }?["discountId"] as? String, "dsc_st")
    }

    func testHandlePaywallOpen_skipsTheWebSecondTrysPricesWhileTheFlagIsOff() async throws {
        try injectPaddleConfig(webSecondTryEnabled: false)
        MockURLProtocol.requestHandler = perPriceHandler()
        let session = secondTryPaywallSession(secondTryProducts: ["pro_st:pri_st"])

        coordinator.handlePaywallOpen(paywallSession: session)
        _ = await coordinator.awaitOutcome(sessionId: session.sessionId, priceId: "pri_main")
        let secondTryOutcome = await coordinator.awaitOutcome(sessionId: session.sessionId, priceId: "pri_st")

        guard case .notStarted = secondTryOutcome else {
            XCTFail("Expected pri_st not to be prefetched, got \(secondTryOutcome)")
            return
        }
        XCTAssertEqual(banditRequestBodies().compactMap { $0["priceId"] as? String }, ["pri_main"])
    }

    /// Lets a second-try prefetch finish on its own, as it does while the user is still on the
    /// paywall.
    private func waitUntilSettled(_ priceId: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while coordinator.settledOutcome(sessionId: testSessionId, priceId: priceId) == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Checkout never waits on the second try: once the paywall's own prices are in, a second-try
    /// price still in flight counts as not ready.
    func testCollectCheckoutOutcomes_secondTryPriceInFlight_doesNotHoldTheCheckout() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        MockURLProtocol.requestHandler = perPriceHandler(heldBanditPriceIds: ["pri_st"], release: release)
        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_main"], paddleClientToken: "test_xyz", iosBundleId: nil)
        _ = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_main")
        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_st"], paddleClientToken: "test_xyz", iosBundleId: nil)

        let start = Date()
        let (paywall, secondTry) = await coordinator.collectCheckoutOutcomes(
            sessionId: testSessionId,
            paywallPriceIds: ["pri_main"],
            secondTryPriceIds: ["pri_st"]
        )
        let elapsed = Date().timeIntervalSince(start)

        guard case .ready = paywall["pri_main"] else {
            XCTFail("Expected pri_main to be .ready, got \(String(describing: paywall["pri_main"]))")
            return
        }
        XCTAssertNil(secondTry["pri_st"])
        XCTAssertLessThan(elapsed, 1, "Checkout waited \(elapsed)s on a second-try price still in flight")
        XCTAssertFalse(WebSecondTryCheckout(info: secondTryInfo, provider: .paddle, paddleOutcomes: secondTry).enabled)
    }

    func testSettledOutcome_isRecordedWhenAPrefetchFinishes_andDroppedWithItsSession() async throws {
        MockURLProtocol.requestHandler = perPriceHandler()
        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_st"], paddleClientToken: "test_xyz", iosBundleId: nil)

        try await waitUntilSettled("pri_st")
        guard case .ready = coordinator.settledOutcome(sessionId: testSessionId, priceId: "pri_st") else {
            XCTFail("Expected pri_st's settled outcome to be .ready")
            return
        }
        XCTAssertNil(coordinator.settledOutcome(sessionId: makeTestSession().sessionId, priceId: "pri_st"))

        coordinator.cancelForSession(sessionId: testSessionId)
        XCTAssertNil(coordinator.settledOutcome(sessionId: testSessionId, priceId: "pri_st"))
    }

    /// The checkout's own guards read only the paywall's outcomes, so a second-try price that
    /// failed costs the second try and never the checkout.
    func testCollectCheckoutOutcomes_failedSecondTryPrice_leavesTheCheckoutReadyAndTheSecondTryOff() async throws {
        MockURLProtocol.requestHandler = perPriceHandler(failingBanditPriceIds: ["pri_st"])
        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_main", "pri_st"], paddleClientToken: "test_xyz", iosBundleId: nil)
        try await waitUntilSettled("pri_st")

        let (paywall, secondTry) = await coordinator.collectCheckoutOutcomes(
            sessionId: testSessionId,
            paywallPriceIds: ["pri_main"],
            secondTryPriceIds: ["pri_st"]
        )

        XCTAssertEqual(Array(paywall.keys), ["pri_main"])
        guard case .ready = paywall["pri_main"] else {
            XCTFail("Expected pri_main to be .ready, got \(String(describing: paywall["pri_main"]))")
            return
        }
        guard case .failed = secondTry["pri_st"] else {
            XCTFail("Expected pri_st to be .failed, got \(String(describing: secondTry["pri_st"]))")
            return
        }
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.tappedShortCircuit(in: paywall, tappedPriceId: "pri_main"))
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.californiaBlockedPostalCode(in: paywall))

        let checkout = WebSecondTryCheckout(info: secondTryInfo, provider: .paddle, paddleOutcomes: secondTry)
        XCTAssertFalse(checkout.enabled)
        XCTAssertEqual(checkout.ctx["enabled"] as? Bool, false)
        XCTAssertTrue(checkout.paddleBootstrapOutcomes.isEmpty)
    }

    func testCollectCheckoutOutcomes_californiaBlockedSecondTryPrice_doesNotBlockTheCheckout() async throws {
        MockURLProtocol.requestHandler = perPriceHandler(californiaPriceIds: ["pri_st"])
        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_main", "pri_st"], paddleClientToken: "test_xyz", iosBundleId: nil)
        try await waitUntilSettled("pri_st")

        let (paywall, secondTry) = await coordinator.collectCheckoutOutcomes(
            sessionId: testSessionId,
            paywallPriceIds: ["pri_main"],
            secondTryPriceIds: ["pri_st"]
        )

        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.californiaBlockedPostalCode(in: paywall))
        XCTAssertEqual(PaddleCheckoutPrefetchCoordinator.californiaBlockedPostalCode(in: secondTry), "90210")
        XCTAssertFalse(WebSecondTryCheckout(info: secondTryInfo, provider: .paddle, paddleOutcomes: secondTry).enabled)
    }

    func testCollectCheckoutOutcomes_readySecondTry_bootstrapsJoinThePaywallsByPrice() async throws {
        MockURLProtocol.requestHandler = perPriceHandler()
        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_main", "pri_st"], paddleClientToken: "test_xyz", iosBundleId: nil)
        try await waitUntilSettled("pri_st")

        let (paywall, secondTry) = await coordinator.collectCheckoutOutcomes(
            sessionId: testSessionId,
            paywallPriceIds: ["pri_main"],
            secondTryPriceIds: ["pri_st"]
        )
        let checkout = WebSecondTryCheckout(info: secondTryInfo, provider: .paddle, paddleOutcomes: secondTry)

        XCTAssertTrue(checkout.enabled)
        let bootstraps = try XCTUnwrap(PaddleCheckoutPrefetchCoordinator.encodeBootstrapsToCtx(
            outcomesByPriceId: PaddleCheckoutPrefetchCoordinator.checkoutCtxOutcomes(paywall: paywall, secondTry: checkout)
        ))
        XCTAssertEqual(Set(bootstraps.keys), ["pri_main", "pri_st"])
        let secondTryBandit = (bootstraps["pri_st"] as? [String: Any])?["banditResponse"] as? [String: Any]
        XCTAssertEqual(secondTryBandit?["transactionId"] as? String, "txn_pri_st")
    }

    /// A price both paywalls offer counts for both.
    func testCollectCheckoutOutcomes_sharedPriceIsInBothSplits() async throws {
        MockURLProtocol.requestHandler = perPriceHandler()
        coordinator.prefetch(paywallSession: testSession, priceIds: ["pri_shared"], paddleClientToken: "test_xyz", iosBundleId: nil)

        let (paywall, secondTry) = await coordinator.collectCheckoutOutcomes(
            sessionId: testSessionId,
            paywallPriceIds: ["pri_shared"],
            secondTryPriceIds: ["pri_shared"]
        )

        guard case .ready = paywall["pri_shared"], case .ready = secondTry["pri_shared"] else {
            XCTFail("Expected pri_shared to be .ready in both splits; got \(paywall) and \(secondTry)")
            return
        }
        XCTAssertEqual(banditRequestBodies().count, 1)
    }

    // MARK: - Checkout ctx outcomes

    func testCheckoutCtxOutcomes_addTheSecondTrysOnlyWhileItIsEnabled() {
        let paywall: [String: PaddlePrefetchOutcome] = [
            "pri_main": .ready(bandit: makeBandit(transactionId: "txn_main"), paddle: makePaddle()),
        ]
        let enabled = WebSecondTryCheckout(info: secondTryInfo, provider: .paddle, paddleOutcomes: [
            "pri_st": .ready(bandit: makeBandit(transactionId: "txn_st"), paddle: makePaddle()),
        ])
        let disabled = WebSecondTryCheckout(info: secondTryInfo, provider: .paddle, paddleOutcomes: [:])

        XCTAssertEqual(
            Set(PaddleCheckoutPrefetchCoordinator.checkoutCtxOutcomes(paywall: paywall, secondTry: enabled).keys),
            ["pri_main", "pri_st"]
        )
        XCTAssertEqual(
            Set(PaddleCheckoutPrefetchCoordinator.checkoutCtxOutcomes(paywall: paywall, secondTry: disabled).keys),
            ["pri_main"]
        )
        XCTAssertEqual(
            Set(PaddleCheckoutPrefetchCoordinator.checkoutCtxOutcomes(paywall: paywall, secondTry: nil).keys),
            ["pri_main"]
        )
    }

    /// A price both offer keeps the paywall's own outcome.
    func testCheckoutCtxOutcomes_keepThePaywallsOutcomeForASharedPrice() {
        let shared = WebSecondTryInfo(paywallUUID: "pw-uuid", paywallVersionUUID: "pwv-uuid", productsOfferedPaddle: ["pro_main:pri_main"])
        let checkout = WebSecondTryCheckout(info: shared, provider: .paddle, paddleOutcomes: [
            "pri_main": .ready(bandit: makeBandit(transactionId: "txn_second_try"), paddle: makePaddle()),
        ])

        let outcomes = PaddleCheckoutPrefetchCoordinator.checkoutCtxOutcomes(
            paywall: ["pri_main": .ready(bandit: makeBandit(transactionId: "txn_paywall"), paddle: makePaddle())],
            secondTry: checkout
        )

        guard case let .ready(bandit, _) = outcomes["pri_main"] else {
            XCTFail("Expected pri_main to be .ready, got \(String(describing: outcomes["pri_main"]))")
            return
        }
        XCTAssertEqual(bandit.transactionId, "txn_paywall")
    }
}
