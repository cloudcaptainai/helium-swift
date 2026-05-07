import XCTest
@testable import Helium

/// Tests for `PaddleCheckoutPrefetchCoordinator` — the orchestrator that
/// runs bandit + Paddle BFF in parallel during paywall display so the
/// click handler can produce `ctx.paddleBootstrap` instantly on Subscribe.
///
/// Outcomes the coordinator produces:
///   * `.ready(bandit, paddle)` — full prefetch succeeded, both responses
///     ready to embed in `ctx.paddleBootstrap`.
///   * `.alreadyEntitled(code, message)` — bandit returned 409
///     `duplicate_subscription`; BFF was skipped. Caller resolves the
///     flow as `preCheckResolved` and fires `purchase_already_entitled`.
///   * `.failed(error)` — transport error, non-2xx, or timeout. Caller
///     opens Safari without `ctx.paddleBootstrap`; bundle does its own
///     fetch (no regression from current behavior).
///   * `.notStarted` — no prefetch was ever scheduled for the
///     `(sessionId, priceId)` pair.
@MainActor
final class PaddleCheckoutPrefetchCoordinatorTests: XCTestCase {

    /// Session id used by every test that doesn't specifically exercise
    /// per-session ownership. Cache key is `(sessionId, priceId)`, so
    /// using a fixed value keeps the rest of the cases simple.
    private let testSessionId = "test_session_default"

    private var session: URLSession!
    private var banditClient: HeliumPaymentAPIClient!
    private var bffClient: PaddleBFFClient!
    private var coordinator: PaddleCheckoutPrefetchCoordinator!

    override func setUp() {
        super.setUp()

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
        // Hard barrier — wait for all in-flight prefetches to actually
        // stop before resetting MockURLProtocol's static state. Without
        // this, leaked Tasks from one test can still capture requests via
        // MockURLProtocol after the next test's setUp clears the captured
        // list, which surfaces as flaky off-by-one assertion failures.
        await coordinator.cancelAllAndAwait()
        MockURLProtocol.reset()
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

    /// Minimal bandit response for tests that only need a "ready" outcome
    /// shape and don't care about the inner field values.
    private func makeBandit(transactionId: String = "txn_x") -> PaddleCreateTransactionForPaywallResponse {
        return PaddleCreateTransactionForPaywallResponse(
            transactionId: transactionId,
            paddleCustomerId: nil,
            isKnownCustomer: false,
            requestId: "req_x"
        )
    }

    /// Minimal paddle BFF result for tests that only need a "ready" outcome
    /// shape — the bytes don't have to be a real Paddle response, the
    /// short-circuit decision tests don't decode them.
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
            sessionId: testSessionId,
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

    // MARK: - alreadyEntitled (Option A from HEL-5326 design)

    func testAwaitOutcome_returnsAlreadyEntitled_whenBanditReturns409Duplicate_andSkipsBFFCall() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains("/paddle/create-transaction-for-paywall") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
                return (response, self.banditDuplicateBody().data(using: .utf8)!)
            }
            // BFF should NEVER be called when bandit returns 409 — the customer
            // already owns the product, no checkout session needed.
            throw NSError(domain: "test", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "BFF was called after bandit 409 — should have short-circuited"])
        }

        coordinator.prefetch(sessionId: testSessionId, priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)
        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_x")

        guard case .alreadyEntitled(let code, let message, _) = outcome else {
            XCTFail("Expected .alreadyEntitled, got \(outcome)")
            return
        }
        XCTAssertEqual(code, "duplicate_subscription")
        XCTAssertTrue(message.contains("already have an active subscription"))

        // Concrete assertion that BFF was skipped — saves a wasted round-trip
        // and matches the bundler's existing kind: 'alreadyEntitled' branch.
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

        coordinator.prefetch(sessionId: testSessionId, priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)
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

        coordinator.prefetch(sessionId: testSessionId, priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)
        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_x")

        guard case .failed = outcome else {
            XCTFail("Expected .failed, got \(outcome)")
            return
        }
    }

    // MARK: - cache misses

    func testAwaitOutcome_returnsNotStarted_whenNoPrefetchWasCalled() async {
        // No call to prefetch — cache is empty.
        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_unknown")

        guard case .notStarted = outcome else {
            XCTFail("Expected .notStarted for priceId never prefetched, got \(outcome)")
            return
        }
    }

    func testAwaitOutcome_returnsNotStarted_forPriceIdNotInPrefetchSet() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        coordinator.prefetch(sessionId: testSessionId, priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)

        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_y_not_prefetched")

        guard case .notStarted = outcome else {
            XCTFail("Expected .notStarted for priceId outside the prefetched set, got \(outcome)")
            return
        }
    }

    /// `(sessionId, priceId)` is a composite key, so the same priceId in
    /// a different session is a different cache entry. A click handler
    /// that asks for the wrong session's priceId must surface
    /// `.notStarted`, not someone else's outcome.
    func testAwaitOutcome_returnsNotStarted_whenSessionIdDoesNotMatch() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        coordinator.prefetch(sessionId: "session_a", priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)

        // Same priceId, different sessionId → cache miss.
        let outcome = await coordinator.awaitOutcome(sessionId: "session_b", priceId: "pri_x")

        guard case .notStarted = outcome else {
            XCTFail("Different session id should be a cache miss; got \(outcome)")
            return
        }
    }

    // MARK: - cancellation

    func testCancelAll_clearsCache_subsequentAwaitsReturnNotStarted() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        coordinator.prefetch(sessionId: testSessionId, priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)
        coordinator.cancelAll()

        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_x")

        guard case .notStarted = outcome else {
            XCTFail("After cancelAll, awaitOutcome should return .notStarted (cache cleared)")
            return
        }
    }

    // MARK: - parallelism

    // MARK: - Timeout on awaitOutcome

    /// `awaitOutcome` blocks the caller until the in-flight Task completes
    /// or the supplied timeout elapses, whichever comes first. Without an
    /// upper bound the prefetch chain could block the Subscribe-tap
    /// handler for up to URLSession's default 60s. On timeout we surface
    /// a `.failed` outcome so the caller defaults to the safety-net path
    /// (open Safari without ctx, bundle does its own fetch) instead of
    /// presenting a frozen UI.
    ///
    /// CRITICAL: this test asserts elapsed wall-clock time, not just the
    /// outcome kind. An implementation that doesn't actually unblock on
    /// timeout — e.g. one whose timeout observer waits on the underlying
    /// task — would still eventually return `.failed` once the network
    /// finishes; only the elapsed-time check rules that out.
    func testAwaitOutcome_timesOut_whenInflightTaskExceedsBudget() async throws {
        // Hang the URLProtocol thread for 2s — well past the 100ms timeout
        // we'll set on awaitOutcome. If the implementation respects the
        // timeout, awaitOutcome returns in ~100ms regardless of how long
        // this Thread.sleep takes.
        MockURLProtocol.requestHandler = { _ in
            Thread.sleep(forTimeInterval: 2.0)
            let response = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        coordinator.prefetch(sessionId: testSessionId, priceIds: ["pri_slow"], paddleClientToken: "test_xyz", iosBundleId: nil)

        let start = Date()
        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_slow", timeout: 0.1)
        let elapsed = Date().timeIntervalSince(start)

        guard case .failed = outcome else {
            XCTFail("Expected .failed (timeout) when the in-flight task exceeds the budget; got \(outcome)")
            return
        }

        // Elapsed should be ~100ms (the timeout). 1s is a generous upper
        // bound that still rules out the buggy "wait for the underlying
        // task to actually complete" behavior (which would be ~2s).
        XCTAssertLessThan(
            elapsed,
            1.0,
            "awaitOutcome with timeout=0.1s should return in well under 1s even if the underlying task hasn't completed; took \(elapsed)s — timeout isn't actually firing"
        )
    }

    /// Default-timeout behavior: when the task completes well within the
    /// budget, awaitOutcome returns the actual outcome (not a timeout).
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

        coordinator.prefetch(sessionId: testSessionId, priceIds: ["pri_fast"], paddleClientToken: "test_xyz", iosBundleId: nil)

        // Generous timeout — task should beat it easily on the synchronous
        // mock URL handler.
        let outcome = await coordinator.awaitOutcome(sessionId: testSessionId, priceId: "pri_fast", timeout: 5.0)

        guard case .ready = outcome else {
            XCTFail("Expected .ready when task completes within timeout; got \(outcome)")
            return
        }
    }

    // MARK: - collectPrefetchOutcomes — wait-for-all before redirect

    /// `collectPrefetchOutcomes` waits for EVERY priceId on the paywall
    /// in parallel before the SDK redirects to Safari. Bundle's purchase
    /// flow can switch products mid-flow; if a non-tapped bootstrap
    /// isn't in ctx when Safari opens, the bundle live-fetches there
    /// instead — defeating the prefetch's "no loader" goal.
    ///
    /// Wall-clock is bounded by the slowest priceId's
    /// `awaitOutcome(default-timeout)` — typically ~0ms because the
    /// user has been reading the paywall for several seconds before
    /// tapping. Worst case: 3s when a priceId's prefetch is genuinely
    /// stuck (resolves to `.failed` via the timeout, encoders skip).
    func testCollectPrefetchOutcomes_returnsAllOutcomesForAllPriceIds() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        coordinator.prefetch(
            sessionId: testSessionId,
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

    /// Empty `priceIds` returns empty outcomes — defensive guard so
    /// callers with no Paddle products on the paywall don't crash.
    func testCollectPrefetchOutcomes_handlesEmptyPriceIds() async throws {
        let outcomes = await coordinator.collectPrefetchOutcomes(
            sessionId: testSessionId,
            priceIds: []
        )
        XCTAssertEqual(outcomes.count, 0)
    }

    /// Single-product paywall is a valid case: just await the one
    /// priceId.
    func testCollectPrefetchOutcomes_handlesSinglePriceId() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        coordinator.prefetch(
            sessionId: testSessionId,
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

    /// `cancelForSession(sessionId:)` clears only the entries owned by
    /// that session. Other in-flight or cached paywall sessions are
    /// untouched. This is the property that makes overlapping paywalls
    /// safe: closing paywall A's prefetch must not destroy paywall B's
    /// cached outcome — even when both share a priceId.
    func testCancelForSession_removesEntriesOwnedByThatSessionOnly() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        // Two sessions, overlapping priceId on purpose to lock in the
        // worst-case scenario.
        coordinator.prefetch(sessionId: "session_a", priceIds: ["pri_shared", "pri_a_only"], paddleClientToken: "test_xyz", iosBundleId: nil)
        coordinator.prefetch(sessionId: "session_b", priceIds: ["pri_shared", "pri_b_only"], paddleClientToken: "test_xyz", iosBundleId: nil)

        coordinator.cancelForSession(sessionId: "session_a")

        let aShared = await coordinator.awaitOutcome(sessionId: "session_a", priceId: "pri_shared", timeout: 5.0)
        let aOnly = await coordinator.awaitOutcome(sessionId: "session_a", priceId: "pri_a_only", timeout: 5.0)
        let bShared = await coordinator.awaitOutcome(sessionId: "session_b", priceId: "pri_shared", timeout: 5.0)
        let bOnly = await coordinator.awaitOutcome(sessionId: "session_b", priceId: "pri_b_only", timeout: 5.0)

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

    /// Builds a representative Paddle BFF response with all the cruft a
    /// real response carries (experimentation block, settings, custom_data,
    /// non-Apple-Pay payment methods, etc.) so trim-assertion tests can
    /// verify we drop everything the bundle doesn't read.
    private func paddleResponseFixtureWithCruft(
        checkoutId: String = "che_x",
        transactionId: String = "txn_test"
    ) throws -> Data {
        let dict: [String: Any] = [
            "data": [
                // Fields the bundle reads ↓
                "id": checkoutId,
                "transaction_id": transactionId,
                "status": "draft",
                "currency_code": "USD",
                "ip_geo_country_code": "US",
                "ip_geo_postal_code": "94102",
                "customer": ["id": "ctm_x", "email": "u@e.com"],
                "seller": ["name": "Helium"],
                "items": [
                    [
                        // Bundle-read sub-fields:
                        "billing_cycle": ["interval": "month", "frequency": 1],
                        "trial_period": ["interval": "day", "frequency": 7],
                        "price": ["unit_price": ["amount": "499", "currency_code": "USD"]],
                        // Cruft to be dropped:
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
                    // Cruft (bundle only reads `.total`):
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
                        // Apple Pay (kept):
                        [
                            "type": "PI_APPLE_PAY",
                            "stripe_options": ["api_key": "pk_test_xxx", "country_code": "US"],
                            // Cruft on the kept entry:
                            "weight": 3,
                            "options": ["api_key": "pk_test_xxx", "country_code": "US"],
                            "seller_friendly_name": "apple-pay",
                            "can_be_saved": false,
                            "one_click": true,
                        ],
                        // Non-Apple-Pay (filtered out):
                        [
                            "type": "CARD",
                            "tokenex_options": ["public_key": "BIG_KEY"],
                            "stripe_options": ["api_key": "pk_test_card", "country_code": "GB"],
                        ],
                        ["type": "PAYPAL", "weight": 2, "options": []],
                    ],
                    // Cruft:
                    "enable_saved_payment_methods": false,
                    "is_payment_processing": false,
                ],
                // Big cruft fields the bundle never reads:
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

    /// `encodeBootstrapsToCtx` produces the map the bundler reads from
    /// `ctx.paddleBootstraps`: keyed by priceId so the bundle can look up
    /// the bootstrap for whichever product the user clicks in Safari, not
    /// just the one tapped in iOS. Two products → two entries.
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

        // Each bootstrap carries banditResponse + paddleCheckoutResponse
        // for ITS priceId. No `priceId` field on the inner bootstrap — the
        // map key already names it.
        XCTAssertNil(aBootstrap["priceId"], "Inner bootstrap shouldn't repeat priceId — the map key is the priceId")
        XCTAssertEqual((aBootstrap["banditResponse"] as? [String: Any])?["transactionId"] as? String, "txn_a")
        XCTAssertEqual((bBootstrap["banditResponse"] as? [String: Any])?["transactionId"] as? String, "txn_b")
    }

    /// Non-`.ready` outcomes (alreadyEntitled / failed / notStarted) don't
    /// belong in the bootstrap map. The bundle's behavior on a missing
    /// entry is the same as today's missing-bootstrap behavior: do its
    /// own fetch. AlreadyEntitled is caller-handled (short-circuit at the
    /// click-handler level) so it must never appear here.
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

    /// Empty / no-ready inputs return nil so the caller can omit the
    /// `paddleBootstraps` field entirely from the ctx (instead of a
    /// pointless empty `{}`).
    func testEncodeBootstrapsToCtx_returnsNilWhenNoReadyOutcomes() {
        let allFailed: [String: PaddlePrefetchOutcome] = [
            "pri_a": .failed(error: NSError(domain: "x", code: 0)),
            "pri_b": .notStarted,
        ]
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.encodeBootstrapsToCtx(outcomesByPriceId: allFailed))
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.encodeBootstrapsToCtx(outcomesByPriceId: [:]))
    }

    /// `paddleCheckoutResponse.data` is trimmed to a documented allow-list
    /// of fields the bundle actually reads (declared by
    /// `PaddleBFFCheckoutData` in heliumStandalonePaddle.ts). The full
    /// Paddle BFF response is ~6KB; trimmed it's ~500 bytes — important
    /// because we're now packing N products' bootstraps into one ctx URL
    /// query parameter, and Safari has practical URL limits.
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

        // Top-level required scalar fields:
        XCTAssertEqual(data["id"] as? String, "che_x")
        XCTAssertEqual(data["transaction_id"] as? String, "txn_test")
        XCTAssertEqual(data["status"] as? String, "draft")
        XCTAssertEqual(data["currency_code"] as? String, "USD")
        XCTAssertEqual(data["ip_geo_country_code"] as? String, "US")
        XCTAssertEqual(data["ip_geo_postal_code"] as? String, "94102")

        // Customer (bundle reads .email for prefilledEmail; .id retained
        // for parity with the typed PaddleBFFCheckoutData interface):
        let customer = try XCTUnwrap(data["customer"] as? [String: Any])
        XCTAssertEqual(customer["email"] as? String, "u@e.com")

        // Seller (only `name` is read for the Apple Pay billing-agreement disclosure):
        let seller = try XCTUnwrap(data["seller"] as? [String: Any])
        XCTAssertEqual(seller["name"] as? String, "Helium")

        // Items — only billing_cycle, trial_period, price.unit_price needed:
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

        // Totals — only `.total` is read:
        let recurring = try XCTUnwrap(data["recurring_totals"] as? [String: Any])
        XCTAssertEqual(recurring["total"] as? Double, 4.99)
        let totals = try XCTUnwrap(data["totals"] as? [String: Any])
        XCTAssertEqual(totals["total"] as? Double, 0)

        // Discount — pass through fully:
        let discount = try XCTUnwrap(data["discount"] as? [String: Any])
        XCTAssertEqual(discount["id"] as? String, "disc_x")
        XCTAssertEqual(discount["recur"] as? Bool, true)

        // Payments — only PI_APPLE_PAY entries kept, only stripe_options inside:
        let payments = try XCTUnwrap(data["payments"] as? [String: Any])
        let methods = try XCTUnwrap(payments["methods_available"] as? [[String: Any]])
        XCTAssertEqual(methods.count, 1, "Non-Apple-Pay methods (CARD, PAYPAL) must be filtered out — bundle never uses them on this path")
        XCTAssertEqual(methods[0]["type"] as? String, "PI_APPLE_PAY")
        let stripeOpts = try XCTUnwrap(methods[0]["stripe_options"] as? [String: Any])
        XCTAssertEqual(stripeOpts["api_key"] as? String, "pk_test_xxx")
        XCTAssertEqual(stripeOpts["country_code"] as? String, "US")
    }

    /// Asserts the trim drops the LARGE cruft fields (experimentation, settings,
    /// custom_data, etc.) — these are 50%+ of the raw response by size. The
    /// trim is the whole point: without it we blow the URL budget once we
    /// pack N products into the ctx.
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

        // Big-payload fields the bundle never reads — drop them.
        for key in [
            "experimentation",   // LD + AB flags, ~2KB
            "settings",          // feature_flags, styles, expires, ~1KB
            "custom_data",       // SDK already knows these
            "type", "is_free", "environment", "created_at",
            "ip_geo_region", "source_page", "messages", "subscription",
        ] {
            XCTAssertNil(data[key], "Field `\(key)` should be dropped by the trim — bundle doesn't read it")
        }

        // Spot-check items[]: per-item totals/product/quantity not read,
        // only billing_cycle/trial_period/price.unit_price are.
        let item = try XCTUnwrap((data["items"] as? [[String: Any]])?.first)
        for key in ["id", "quantity", "totals", "recurring_totals", "product", "price_id", "tax_rate"] {
            XCTAssertNil(item[key], "items[].\(key) should be dropped by the trim")
        }
        // The kept item.price object should ONLY contain unit_price (no `id`, no `name`):
        let price = try XCTUnwrap(item["price"] as? [String: Any])
        XCTAssertEqual(Set(price.keys), ["unit_price"], "items[].price should only contain unit_price")

        // Spot-check the kept Apple Pay method has only `type` + `stripe_options`:
        let methods = try XCTUnwrap((data["payments"] as? [String: Any])?["methods_available"] as? [[String: Any]])
        XCTAssertEqual(Set(methods[0].keys), ["type", "stripe_options"],
                       "Apple Pay entry should be trimmed to {type, stripe_options} only")
    }

    // MARK: - Already-entitled encoding for non-tapped products

    /// `encodeAlreadyEntitledToCtx` produces the map the bundler reads
    /// from `ctx.paddleAlreadyEntitled`, keyed by priceId. Each entry
    /// carries `(code, message)` from bandit's 409 response so the
    /// bundle can short-circuit to its `kind: 'alreadyEntitled'` branch
    /// instantly when the user clicks an entitled product in Safari —
    /// no loader, no round-trip.
    ///
    /// Without this map, the bundle's only way to know a non-tapped
    /// product is entitled is to call bandit itself when the user
    /// clicks it — which defeats the whole point of pre-fetching.
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

    /// Only `.alreadyEntitled` outcomes belong in the map. `.ready`
    /// goes into `paddleBootstraps` separately; `.failed` and
    /// `.notStarted` are dropped (bundle defaults to live-fetch for
    /// missing entries — same as for ready products that didn't
    /// pre-fetch successfully).
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

    /// `existingSubscriptionId` flows into the encoded entry when the
    /// SDK extracted one from bandit's 409 body. Bundle uses it for
    /// `canonicalJoinTransactionId` in the `helium_purchase_already_entitled`
    /// Jitsu fire — without this thread-through, the prefetched
    /// alreadyEntitled path's analytics would be missing the field that
    /// the live-fetch path emits.
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

    /// When the SDK didn't extract an existingSubscriptionId (the 409
    /// body didn't include any of the recognized id paths), the encoded
    /// entry omits the field entirely — bundle's null-check branches
    /// gracefully on missing data.
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

    /// Empty / no-entitled inputs return nil so the caller can omit the
    /// `paddleAlreadyEntitled` field from the ctx (instead of a
    /// pointless empty `{}`).
    func testEncodeAlreadyEntitledToCtx_returnsNilWhenNoEntitledOutcomes() {
        let allReady: [String: PaddlePrefetchOutcome] = [
            "pri_a": .ready(bandit: makeBandit(), paddle: makePaddle()),
        ]
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.encodeAlreadyEntitledToCtx(outcomesByPriceId: allReady))
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.encodeAlreadyEntitledToCtx(outcomesByPriceId: [:]))
    }

    // MARK: - Tapped-product short-circuit decision

    /// `tappedShortCircuit` is the pure decision the click handler makes
    /// after collecting prefetch outcomes for every priceId on the
    /// paywall: should we skip Safari and resolve the flow as
    /// `preCheckResolved` because the user *specifically tapped* a
    /// product they already own?
    ///
    /// Critical: ONLY the tapped priceId's outcome can trigger the
    /// short-circuit. Other priceIds being alreadyEntitled (e.g. user
    /// already owns yearly but tapped monthly) must NOT block the
    /// monthly purchase. This is the property the test below locks in.
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

    /// The most important behavioral guarantee: a non-tapped priceId
    /// being alreadyEntitled must NOT short-circuit the tapped product.
    /// Real scenario: user owns yearly, paywall offers monthly + yearly,
    /// user taps monthly — they should be allowed to purchase monthly.
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
        // No prefetch ran for the tapped priceId (older paywall config,
        // race condition, etc.). Default to opening Safari, not blocking.
        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_other": .alreadyEntitled(code: "duplicate_subscription", message: "x", existingSubscriptionId: nil),
        ]
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.tappedShortCircuit(
            in: outcomes, tappedPriceId: "pri_tapped"
        ))
    }

    /// Only `duplicate_subscription` is restorable. Other alreadyEntitled-
    /// class codes (specifically `trial_already_used`) represent a
    /// failure UX in the bundle (entitled_failure → paymentFailureUrl
    /// redirect). The SDK opens the bundle for those instead of firing
    /// `PurchaseRestoredEvent` directly. Mirrors the bundler's
    /// `routePaddle409` behavior.
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
        "trial_already_used must NOT short-circuit — it routes to entitled_failure on the bundle, not entitled_success")
    }

    func testTappedShortCircuit_whenTappedIsFailed_returnsNil() {
        // .failed → bundle does its own fetch; not a short-circuit.
        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_tapped": .failed(error: NSError(domain: "x", code: 0)),
        ]
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.tappedShortCircuit(
            in: outcomes, tappedPriceId: "pri_tapped"
        ))
    }

    // MARK: - Composite key extraction (click-handler integration)

    /// Paywall info stores Paddle products as "pro_xxx:pri_yyy" composite
    /// keys (mirrors Stripe's encoding). The coordinator needs to extract
    /// just the priceId portion to pass to the bandit + BFF chain.
    func testExtractPriceIds_extractsPriPrefixedSuffixesFromCompositeKeys() {
        let composites = [
            "pro_01abc:pri_01xyz",
            "pro_01def:pri_01def_yearly",
        ]
        let priceIds = PaddleCheckoutPrefetchCoordinator.extractPriceIds(from: composites)
        XCTAssertEqual(priceIds, ["pri_01xyz", "pri_01def_yearly"])
    }

    /// A key with no colon but a `pri_` prefix (e.g. "pri_just_a_priceid")
    /// must be rejected — the composite-key contract is "pro_xxx:pri_yyy",
    /// and "no colon" means "not a composite", regardless of prefix.
    func testExtractPriceId_rejectsKeyWithNoColon() {
        XCTAssertNil(
            PaddleCheckoutPrefetchCoordinator.extractPriceId(from: "pri_just_a_priceid"),
            "A key without a colon is not a composite key, even if it starts with `pri_`."
        )
    }

    func testExtractPriceId_rejectsKeyWithMultipleColons() {
        // Defensive: more than one colon means the input is malformed in
        // a way the contract doesn't cover. Skip rather than trying to
        // guess which segment is the priceId.
        XCTAssertNil(
            PaddleCheckoutPrefetchCoordinator.extractPriceId(from: "pro_x:extra:pri_y")
        )
    }

    func testExtractPriceIds_skipsMalformedCompositeKeys() {
        // Defensive: a malformed composite key shouldn't crash the prefetch
        // chain. Skip it and proceed with whatever IS valid.
        let composites = [
            "pro_01abc:pri_valid",          // happy path
            "no_colon_here",                // missing colon → not a composite
            "pro_01def:NOT_pri_prefixed",   // suffix doesn't look like a priceId
            "",                             // empty
            ":pri_orphan",                  // missing productId half
            "pro_x:extra:pri_y",            // too many colons
        ]
        let priceIds = PaddleCheckoutPrefetchCoordinator.extractPriceIds(from: composites)
        XCTAssertEqual(priceIds, ["pri_valid"])
    }

    func testExtractPriceIds_returnsEmptyForEmptyInput() {
        XCTAssertEqual(PaddleCheckoutPrefetchCoordinator.extractPriceIds(from: []), [])
    }

    // MARK: - Parallel prefetch

    func testPrefetch_runsMultiplePriceIdsInParallel() async throws {
        // Both succeed; coordinator should produce ready outcomes for both.
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            // Use the URL to derive which "transaction" we're returning so
            // the test can sanity-check the per-priceId pairing.
            if url.contains("/paddle/create-transaction-for-paywall") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                // Bandit responses for the test don't actually need to differ
                // per priceId — the priceId is only echoed via productPriceId
                // in the request body. We just need both to succeed.
                return (response, self.banditSuccessBody(transactionId: "txn_some").data(using: .utf8)!)
            } else if url.contains("/transaction-checkout") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (response, self.bffSuccessBody(checkoutId: "che_some", transactionId: "txn_some").data(using: .utf8)!)
            }
            throw NSError(domain: "test", code: 0)
        }

        coordinator.prefetch(
            sessionId: testSessionId,
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

        // 2 priceIds × 2 calls each (bandit + BFF) = 4 total requests.
        // Test isolation guaranteed by tearDown's `cancelAllAndAwait`.
        let urls = MockURLProtocol.capturedRequests.compactMap { $0.url?.absoluteString }
        let banditCalls = urls.filter { $0.contains("/paddle/create-transaction-for-paywall") }
        let bffCalls = urls.filter { $0.contains("/transaction-checkout") && !$0.contains("/paddle/create-transaction-for-paywall") }
        XCTAssertEqual(banditCalls.count, 2, "Expected 2 bandit calls (one per priceId)")
        XCTAssertEqual(bffCalls.count, 2, "Expected 2 BFF calls (one per priceId)")
    }
}
