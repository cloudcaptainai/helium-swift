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

        guard case .alreadyEntitled(let code, let message) = outcome else {
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

    /// `.ready` outcomes encode into the ctx as a `paddleBootstrap` object
    /// the bundler reads to skip its own bandit + BFF round-trips. The
    /// banditResponse fields are flat (typed ones we already decoded);
    /// the paddleCheckoutResponse is the full raw Paddle BFF body so the
    /// bundle's existing decoder can consume it.
    func testEncodeBootstrapToCtx_returnsDict_whenReady() throws {
        let bandit = PaddleCreateTransactionForPaywallResponse(
            transactionId: "txn_test",
            paddleCustomerId: "ctm_test",
            isKnownCustomer: true,
            requestId: "req_test"
        )
        let paddleBody = """
        {"data":{"id":"che_x","transaction_id":"txn_test","status":"draft"}}
        """.data(using: .utf8)!
        let paddle = PaddleTransactionCheckoutResult(
            rawBody: paddleBody,
            checkoutId: "che_x",
            transactionId: "txn_test"
        )
        let outcome: PaddlePrefetchOutcome = .ready(bandit: bandit, paddle: paddle)

        let dict = try XCTUnwrap(
            PaddleCheckoutPrefetchCoordinator.encodeBootstrapToCtx(
                outcome,
                priceId: "pri_xyz"
            )
        )

        // priceId is included explicitly so the bundler can match against
        // the user's selected product without reading it out of Paddle's
        // response shape (relying on `items[0].price_id` would be a
        // fragile schema dependency on Paddle's response).
        XCTAssertEqual(dict["priceId"] as? String, "pri_xyz")

        let banditDict = try XCTUnwrap(dict["banditResponse"] as? [String: Any])
        XCTAssertEqual(banditDict["transactionId"] as? String, "txn_test")
        XCTAssertEqual(banditDict["paddleCustomerId"] as? String, "ctm_test")
        XCTAssertEqual(banditDict["isKnownCustomer"] as? Bool, true)

        // paddleCheckoutResponse must round-trip the full Paddle response —
        // bundle reads many fields off this (currency_code, ip_geo_*, items,
        // totals, methods_available[].stripe_options.api_key, etc.). Lock in
        // that we don't accidentally pluck just a few fields.
        let paddleDict = try XCTUnwrap(dict["paddleCheckoutResponse"] as? [String: Any])
        let paddleData = try XCTUnwrap(paddleDict["data"] as? [String: Any])
        XCTAssertEqual(paddleData["id"] as? String, "che_x")
        XCTAssertEqual(paddleData["transaction_id"] as? String, "txn_test")
    }

    func testEncodeBootstrapToCtx_returnsNil_whenAlreadyEntitled() {
        // alreadyEntitled doesn't go through Safari at all, so there's
        // nothing to encode in ctx. The caller short-circuits before
        // building the URL.
        let outcome: PaddlePrefetchOutcome = .alreadyEntitled(code: "duplicate_subscription", message: "x")
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.encodeBootstrapToCtx(outcome, priceId: "pri_xyz"))
    }

    func testEncodeBootstrapToCtx_returnsNil_whenFailedOrNotStarted() {
        // Both should default to the bundle doing its own fetch — no
        // ctx.paddleBootstrap means the bundle hits its existing code path.
        let failed: PaddlePrefetchOutcome = .failed(error: NSError(domain: "x", code: 0))
        let notStarted: PaddlePrefetchOutcome = .notStarted
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.encodeBootstrapToCtx(failed, priceId: "pri_xyz"))
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.encodeBootstrapToCtx(notStarted, priceId: "pri_xyz"))
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
