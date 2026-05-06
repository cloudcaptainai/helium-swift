import XCTest
@testable import Helium

/// Tests for `PaddleCheckoutPrefetchCoordinator` (Stage 4 of HEL-5326).
///
/// The coordinator combines the bandit client (Stage 2) and the Paddle BFF
/// client (Stage 3) to run the full pre-fetch chain in the background per
/// priceId, caches the in-flight Tasks keyed by priceId, and exposes
/// `awaitOutcome(priceId:)` which the click handler uses on Subscribe to
/// either get an instant cached result or wait for an in-flight one.
///
/// Outcomes the coordinator produces:
///   * `.ready(bandit, paddle)` — full prefetch succeeded, both responses
///     ready to embed in `ctx.paddleBootstrap`.
///   * `.alreadyEntitled(code, message)` — bandit returned 409
///     `duplicate_subscription`. BFF was never called (we don't waste a
///     round-trip when the customer already owns the product). Stage 5
///     translates this to `preCheckResolved` + `purchase_already_entitled`
///     event.
///   * `.failed(error)` — transport error or non-2xx from either call.
///     Stage 5 falls back to opening Safari without `ctx.paddleBootstrap`
///     and the bundle does its own fetch (current behavior, no regression).
///   * `.notStarted` — no prefetch ever ran for this priceId. Stage 5
///     falls back the same way as `.failed`.
@MainActor
final class PaddleCheckoutPrefetchCoordinatorTests: XCTestCase {

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
            priceIds: ["pri_x"],
            paddleClientToken: "test_xyz",
            iosBundleId: "com.example.test"
        )

        let outcome = await coordinator.awaitOutcome(priceId: "pri_x")

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

        coordinator.prefetch(priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)
        let outcome = await coordinator.awaitOutcome(priceId: "pri_x")

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

        coordinator.prefetch(priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)
        let outcome = await coordinator.awaitOutcome(priceId: "pri_x")

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

        coordinator.prefetch(priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)
        let outcome = await coordinator.awaitOutcome(priceId: "pri_x")

        guard case .failed = outcome else {
            XCTFail("Expected .failed, got \(outcome)")
            return
        }
    }

    // MARK: - cache misses

    func testAwaitOutcome_returnsNotStarted_whenNoPrefetchWasCalled() async {
        // No call to prefetch — cache is empty.
        let outcome = await coordinator.awaitOutcome(priceId: "pri_unknown")

        guard case .notStarted = outcome else {
            XCTFail("Expected .notStarted for priceId never prefetched, got \(outcome)")
            return
        }
    }

    func testAwaitOutcome_returnsNotStarted_forPriceIdNotInPrefetchSet() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        coordinator.prefetch(priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)

        let outcome = await coordinator.awaitOutcome(priceId: "pri_y_not_prefetched")

        guard case .notStarted = outcome else {
            XCTFail("Expected .notStarted for priceId outside the prefetched set, got \(outcome)")
            return
        }
    }

    // MARK: - cancellation

    func testCancelAll_clearsCache_subsequentAwaitsReturnNotStarted() async throws {
        MockURLProtocol.requestHandler = bothSucceedHandler()

        coordinator.prefetch(priceIds: ["pri_x"], paddleClientToken: "test_xyz", iosBundleId: nil)
        coordinator.cancelAll()

        let outcome = await coordinator.awaitOutcome(priceId: "pri_x")

        guard case .notStarted = outcome else {
            XCTFail("After cancelAll, awaitOutcome should return .notStarted (cache cleared)")
            return
        }
    }

    // MARK: - parallelism

    // MARK: - Bootstrap encoding for ctx (Stage 6)

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

        let dict = try XCTUnwrap(PaddleCheckoutPrefetchCoordinator.encodeBootstrapToCtx(outcome))

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
        // nothing to encode in ctx. Stage 5's caller short-circuits before
        // building the URL.
        let outcome: PaddlePrefetchOutcome = .alreadyEntitled(code: "duplicate_subscription", message: "x")
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.encodeBootstrapToCtx(outcome))
    }

    func testEncodeBootstrapToCtx_returnsNil_whenFailedOrNotStarted() {
        // Both should fall back to the bundle doing its own fetch — no
        // ctx.paddleBootstrap means the bundle hits its existing code path.
        let failed: PaddlePrefetchOutcome = .failed(error: NSError(domain: "x", code: 0))
        let notStarted: PaddlePrefetchOutcome = .notStarted
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.encodeBootstrapToCtx(failed))
        XCTAssertNil(PaddleCheckoutPrefetchCoordinator.encodeBootstrapToCtx(notStarted))
    }

    // MARK: - Composite key extraction (Stage 5 integration helper)

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

    func testExtractPriceIds_skipsEntriesWithoutColonOrPriPrefix() {
        // Defensive: a malformed composite key shouldn't crash the prefetch
        // chain. Skip it and proceed with whatever IS valid.
        let composites = [
            "pro_01abc:pri_valid",
            "no_colon_here",
            "pro_01def:NOT_pri_prefixed",
            "",
            ":pri_orphan",
        ]
        let priceIds = PaddleCheckoutPrefetchCoordinator.extractPriceIds(from: composites)
        // ":pri_orphan" splits on ":" → last is "pri_orphan", which has the
        // pri_ prefix — so it gets through. That's fine; bandit will reject
        // an actually-invalid priceId at the API boundary anyway.
        XCTAssertEqual(priceIds, ["pri_valid", "pri_orphan"])
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
            priceIds: ["pri_a", "pri_b"],
            paddleClientToken: "test_xyz",
            iosBundleId: nil
        )

        let outcomeA = await coordinator.awaitOutcome(priceId: "pri_a")
        let outcomeB = await coordinator.awaitOutcome(priceId: "pri_b")

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
