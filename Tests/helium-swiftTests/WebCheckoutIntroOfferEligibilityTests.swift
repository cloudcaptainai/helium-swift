import XCTest
@testable import Helium

private final class FixedWebEntitlementsSource: HeliumPaymentEntitlementsSource, @unchecked Sendable {
    let productKeys: Set<String>

    init(provider: PaymentProviderConfig, productKeys: Set<String>) {
        self.productKeys = productKeys
        super.init(provider: provider)
    }

    override func refreshEntitlements() async {}
    override func purchasedHeliumProductIds() async -> Set<String> { productKeys }
}

/// Covers the price-map derivation used when `/check-entitlement` returns no
/// eligibility value. Fixtures are decoded from JSON rather than hand-built, so
/// a field rename surfaces here.
final class WebCheckoutIntroOfferEligibilityTests: XCTestCase {

    @MainActor
    func testSecondTryRejectsOtherProviderProducts() {
        for provider in [PaymentProviderConfig.paddle, .stripe] {
            let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: FixedWebEntitlementsSource(provider: provider, productKeys: []))
            for includesOwnProduct in [false, true] {
                var info = makeTestPaywallInfo()
                info.webSecondTryConfig = WebSecondTryConfig(
                    paywallId: "b", versionId: "v", bundleUrl: "https://example.com/b",
                    productsOfferedPaddle: provider.kind == .stripe || includesOwnProduct ? ["pro_b:pri_b"] : [],
                    productsOfferedStripe: provider.kind == .paddle || includesOwnProduct ? ["prod_b:price_b"] : [],
                    triggers: ["dismissed"]
                )
                XCTAssertNil(manager.readySecondTry(paywallSession: makeTestSession(paywallInfo: info), entitledBefore: []))
            }
        }
    }

    @MainActor
    func testStripeSecondTryUsesCheckoutEntitlements() throws {
        let key = "prod_b:price_b"
        let manager = ExternalWebCheckoutManager(provider: .stripe, entitlementsSource: FixedWebEntitlementsSource(provider: .stripe, productKeys: []))
        var info = makeTestPaywallInfo()
        info.webSecondTryConfig = WebSecondTryConfig(
            paywallId: "b", versionId: "v", bundleUrl: "https://example.com/b",
            productsOfferedPaddle: [], productsOfferedStripe: [key], triggers: ["dismissed"]
        )
        let session = makeTestSession(paywallInfo: info)
        let config = HeliumFetchedConfigManager.shared
        defer { HeliumFetchedConfigManager.reset() }
        config.setPreviewServerProducts(stripeProducts: [key: try price(key, .eligibleTrial)], paddleProducts: nil, paddleClientToken: nil)
        let ready = try XCTUnwrap(manager.readySecondTry(paywallSession: session, entitledBefore: []))
        let context = try XCTUnwrap(ready.context["perPaywallCtx"] as? [String: Any])
        XCTAssertEqual(context["initialStripeSelection"] as? String, key)
        XCTAssertNotNil((context["stripeOfferTerms"] as? [String: Any])?[key])
        XCTAssertNil(manager.readySecondTry(paywallSession: session, entitledBefore: ["prod_b:price_other"]))
    }

    @MainActor
    func testSecondTryPurchaseIsDetectedOnlyWhenSecondTryWasPresented() async {
        for provider in [PaymentProviderConfig.paddle, .stripe] {
            let key = provider.kind == .paddle ? "pro_b:pri_b" : "prod_b:price_b"
            let source = FixedWebEntitlementsSource(provider: provider, productKeys: [key])
            let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: source)
            var info = makeTestPaywallInfo()
            info.webProductsOfferedPaddle = ["pro_a:pri_a"]
            info.webProductsOfferedStripe = ["prod_a:price_a"]
            let session = makeTestSession(paywallInfo: info)
            let second = WebSecondTryConfig(
                paywallId: "b", versionId: "v", bundleUrl: "https://example.com/b",
                productsOfferedPaddle: provider.kind == .paddle ? [key] : [],
                productsOfferedStripe: provider.kind == .stripe ? [key] : [], triggers: ["dismissed"]
            )
            manager.observeCheckout(paywallSession: session, entitledProductIdsBeforeCheckout: [], secondTry: nil)
            let missing = await manager.checkForNewPurchase()
            XCTAssertFalse(missing)
            manager.observeCheckout(paywallSession: session, entitledProductIdsBeforeCheckout: [], secondTry: second)
            let detected = await manager.checkForNewPurchase()
            XCTAssertTrue(detected)
        }
    }

    override func setUp() {
        super.setUp()
        HeliumObservabilityManager.shared.unitTestTrackObserver = nil
    }

    override func tearDown() {
        HeliumObservabilityManager.shared.unitTestTrackObserver = nil
        super.tearDown()
    }

    /// Price fixtures, named for what they represent and defined by the fields
    /// they carry.
    private enum Shape {
        /// `introOfferEligible: true`, `introOffers` non-empty.
        case eligibleTrial
        /// `introOfferEligible: false`, `introOffers` omitted — a trial the
        /// customer has already consumed.
        case consumedTrial
        /// `introOfferEligible: false`, `introOffers` omitted — a price with no
        /// trial at all. Identical on the wire to `consumedTrial`, which is why
        /// offer-bearing is keyed on `introOffers`.
        case noTrial
        /// No `subscription` block.
        case oneTime
        /// `introOfferEligible: false`, `introOffers` non-empty. Pins that an
        /// offer-bearing price reporting ineligible still fails the check.
        case offerButIneligible
    }

    private func price(_ productKey: String, _ shape: Shape) throws -> ServerProductPrice {
        let parts = productKey.split(separator: ":")
        var json: [String: Any] = [
            "id": String(parts[0]),
            "priceId": String(parts[1]),
            "formattedPrice": "$29.99",
            "currency": "USD",
            "productType": shape == .oneTime ? "one_time" : "subscription",
        ]
        if shape != .oneTime {
            var sub: [String: Any] = [
                "period": "P1Y", "periodUnit": "year", "periodValue": 1,
                "introOfferEligible": shape == .eligibleTrial,
            ]
            if shape == .eligibleTrial || shape == .offerButIneligible {
                sub["introOffers"] = [[
                    "type": "IntroOffer", "displayPrice": "Free",
                    "periodUnit": "day", "periodValue": 7, "periodCount": 1,
                    "paymentMode": "FreeTrial",
                ]]
            }
            json["subscription"] = sub
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(ServerProductPrice.self, from: data)
    }

    private func map(_ entries: [(String, Shape)]) throws -> [String: ServerProductPrice] {
        var result: [String: ServerProductPrice] = [:]
        for (key, shape) in entries {
            result[key] = try price(key, shape)
        }
        return result
    }

    private let yearlyTrial = "pro_yearly:pri_trial_7d"
    private let monthlyNoTrial = "pro_monthly:pri_main_monthly"
    private let lifetime = "pro_lifetime:pri_one_time"

    // MARK: - The reported defect

    func testNoTrialProductDoesNotMaskAnEligibleCustomer() throws {
        // A web paywall offering a yearly trial next to a monthly plan with no
        // trial. The monthly entry is false for every customer because it has no
        // trial at all, so it is not offer-bearing and must not be counted.
        let priceMap = try map([(yearlyTrial, .eligibleTrial), (monthlyNoTrial, .noTrial)])

        XCTAssertTrue(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [monthlyNoTrial, yearlyTrial], priceMap: priceMap))
    }

    func testOrderOfOfferedProductsDoesNotMatter() throws {
        let priceMap = try map([(yearlyTrial, .eligibleTrial), (monthlyNoTrial, .noTrial)])

        XCTAssertTrue(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [yearlyTrial, monthlyNoTrial], priceMap: priceMap))
    }

    func testOneTimeProductDoesNotMaskAnEligibleCustomer() throws {
        let priceMap = try map([(yearlyTrial, .eligibleTrial), (lifetime, .oneTime)])

        XCTAssertTrue(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [lifetime, yearlyTrial], priceMap: priceMap))
    }

    // MARK: - Cases that must stay false

    func testConsumedTrialIsFalse() throws {
        // A consumed trial arrives with no introOffers, so no price on the
        // paywall is offer-bearing.
        let priceMap = try map([(yearlyTrial, .consumedTrial), (monthlyNoTrial, .noTrial)])

        XCTAssertFalse(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [yearlyTrial, monthlyNoTrial], priceMap: priceMap))
    }

    func testPaywallWithNoTrialsAtAllIsFalse() throws {
        let priceMap = try map([(monthlyNoTrial, .noTrial)])

        XCTAssertFalse(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [monthlyNoTrial], priceMap: priceMap))
    }

    func testEmptyProductListIsFalse() throws {
        let priceMap = try map([(yearlyTrial, .eligibleTrial)])

        XCTAssertFalse(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [], priceMap: priceMap))
    }

    func testProductMissingFromPriceMapIsFalse() throws {
        XCTAssertFalse(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [yearlyTrial], priceMap: [:]))
    }

    func testPreCheckSkipsCheckoutUsesExactMatchWhenFlagIsOff() {
        XCTAssertTrue(ExternalWebCheckoutManager.preCheckSkipsCheckout(
            entitledIds: [yearlyTrial],
            productKey: yearlyTrial,
            offeredProductKeys: [monthlyNoTrial],
            a2wEnabled: false
        ))
        XCTAssertFalse(ExternalWebCheckoutManager.preCheckSkipsCheckout(
            entitledIds: ["pro_yearly:pri_other"],
            productKey: yearlyTrial,
            offeredProductKeys: [yearlyTrial],
            a2wEnabled: false
        ))
    }

    func testPreCheckSkipsCheckoutRequiresEveryOfferedPriceWhenFlagIsOn() {
        let weekly = "pro_a:pri_weekly"
        let annual = "pro_a:pri_annual"

        XCTAssertFalse(ExternalWebCheckoutManager.preCheckSkipsCheckout(
            entitledIds: [weekly],
            productKey: weekly,
            offeredProductKeys: [weekly, annual],
            a2wEnabled: true
        ))
        XCTAssertTrue(ExternalWebCheckoutManager.preCheckSkipsCheckout(
            entitledIds: [weekly, annual],
            productKey: weekly,
            offeredProductKeys: [weekly, annual],
            a2wEnabled: true
        ))
        XCTAssertFalse(ExternalWebCheckoutManager.preCheckSkipsCheckout(
            entitledIds: [weekly, annual],
            productKey: "pro_a:pri_unlisted",
            offeredProductKeys: [weekly, annual],
            a2wEnabled: true
        ))
        XCTAssertTrue(ExternalWebCheckoutManager.preCheckSkipsCheckout(
            entitledIds: [weekly],
            productKey: weekly,
            offeredProductKeys: [],
            a2wEnabled: true
        ))
    }

    func testOnlyOneTimeProductsIsFalse() throws {
        let priceMap = try map([(lifetime, .oneTime)])

        XCTAssertFalse(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [lifetime], priceMap: priceMap))
    }

    // MARK: - Every offer-bearing product must agree

    func testOfferBearingButIneligibleFailsTheCheck() throws {
        // Pins the contract as "every offer-bearing product is eligible" rather
        // than "any product is eligible", should a price ever arrive carrying an
        // offer the customer is not eligible for.
        let priceMap = try map([
            (yearlyTrial, .eligibleTrial),
            ("pro_yearly:pri_trial_14d", .offerButIneligible),
        ])

        XCTAssertFalse(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [yearlyTrial, "pro_yearly:pri_trial_14d"], priceMap: priceMap))
    }

    func testUnknownProductAlongsideAnEligibleOneIsStillTrue() throws {
        let priceMap = try map([(yearlyTrial, .eligibleTrial)])

        XCTAssertTrue(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: ["pro_ghost:pri_missing", yearlyTrial], priceMap: priceMap))
    }

    func testNonUSPrefetchOutcomeThrowsBuyerBlockedCheckoutError() {
        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_non_us": .failed(error: PaddleNonUSBuyerBlocked(countryCode: "MX")),
        ]

        XCTAssertThrowsError(try ExternalWebCheckoutManager.throwIfNonUSBuyerBlocked(in: outcomes)) { error in
            XCTAssertEqual((error as? WebCheckoutError)?.caseName, "nonUSBuyerBlocked")
            XCTAssertTrue(error.localizedDescription.contains("MX"))
        }
    }

    func testEmitPaddleAwaitResolvedCountsNonUSBlockedSeparately() {
        var capturedEvents: [any HeliumObservabilityEvent] = []
        HeliumObservabilityManager.shared.unitTestTrackObserver = { capturedEvents.append($0) }

        let bandit = PaddleCreateTransactionForPaywallResponse(
            transactionId: "txn_ready",
            paddleCustomerId: nil,
            isKnownCustomer: false,
            requestId: "req_ready"
        )
        let paddle = PaddleTransactionCheckoutResult(
            rawBody: "{}".data(using: .utf8)!,
            checkoutId: "che_ready",
            transactionId: "txn_ready"
        )
        let manager = ExternalWebCheckoutManager(
            provider: .paddle,
            entitlementsSource: PaddleEntitlementsSource()
        )

        manager.emitPaddleAwaitResolved(
            tappedPriceId: "pri_a",
            awaitDurationMs: 12,
            outcomes: [
                "pri_a": .failed(error: PaddleNonUSBuyerBlocked(countryCode: "MX")),
                "pri_b": .ready(bandit: bandit, paddle: paddle),
            ],
            shortCircuited: false,
            paywallSession: makeTestSession()
        )

        let awaitResolvedEvents = capturedEvents
            .compactMap { $0 as? PaddlePrefetchAwaitResolved }
            .filter { $0.tappedPriceId == "pri_a" }

        XCTAssertEqual(awaitResolvedEvents.count, 1)
        guard let event = awaitResolvedEvents.first else {
            XCTFail("Expected one PaddlePrefetchAwaitResolved event for the tapped price")
            return
        }

        XCTAssertEqual(event.nonUSBlockedCount, 1)
        XCTAssertEqual(event.readyCount, 1)
        XCTAssertEqual(event.failedCount, 0)
        XCTAssertEqual(event.caBlockedCount, 0)
    }

    // MARK: - Already-owned pre-check refresh

    private static let ownedKey = "prod_owned:price_owned"

    private var preCheckSource: HeliumPaymentEntitlementsSource!

    private func seedOwnedEntitlement(seedOwned: Bool = true) -> ExternalWebCheckoutManager {
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        Helium.lastApiKeyUsed = "test_api_key_for_precheck_tests"
        preCheckSource = HeliumPaymentEntitlementsSource(provider: .stripe)
        if seedOwned {
            preCheckSource.didCompletePurchase(
                productId: "prod_owned",
                priceId: "price_owned",
                subscriptionExpiresAt: Date().addingTimeInterval(3600)
            )
        }
        return ExternalWebCheckoutManager(provider: .stripe, entitlementsSource: preCheckSource)
    }

    private func tearDownPreCheck() {
        preCheckSource?.clearEntitlements()
        preCheckSource = nil
        Helium.lastApiKeyUsed = nil
        MockURLProtocol.reset()
        URLProtocol.unregisterClass(MockURLProtocol.self)
    }

    private func stubCheckEntitlement(subscriptions: [[String: Any]], delay: TimeInterval = 0) {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix("stripe/check-entitlement") == true, "Unexpected request: \(request.url?.absoluteString ?? "nil")")
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let body = try JSONSerialization.data(withJSONObject: [
                "hasActiveEntitlement": !subscriptions.isEmpty,
                "subscriptions": subscriptions,
            ])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, body)
        }
    }

    private var activeOwnedSubscription: [String: Any] {
        [
            "subscriptionId": "sub_1",
            "productId": "prod_owned",
            "status": "active",
            "priceId": "price_owned",
            "currentPeriodEnd": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)),
        ]
    }

    func testPreCheck_notOwned_skipsNetwork() async {
        let manager = seedOwnedEntitlement()
        defer { tearDownPreCheck() }
        stubCheckEntitlement(subscriptions: [])

        let ids = await manager.entitledProductIdsBeforeCheckout(productKey: "prod_other:price_other")

        XCTAssertEqual(ids, [Self.ownedKey])
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty)
    }

    func testPreCheck_owned_serverConfirms_staysOwned() async {
        let manager = seedOwnedEntitlement()
        defer { tearDownPreCheck() }
        stubCheckEntitlement(subscriptions: [activeOwnedSubscription])

        let ids = await manager.entitledProductIdsBeforeCheckout(productKey: Self.ownedKey)

        XCTAssertTrue(ids.contains(Self.ownedKey))
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
    }

    func testPreCheck_owned_serverSaysExpired_continuesToCheckout() async {
        let manager = seedOwnedEntitlement()
        defer { tearDownPreCheck() }
        stubCheckEntitlement(subscriptions: [])

        let ids = await manager.entitledProductIdsBeforeCheckout(productKey: Self.ownedKey)

        XCTAssertFalse(ids.contains(Self.ownedKey))
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        let cachedAfter = await preCheckSource.purchasedHeliumProductIds()
        XCTAssertFalse(cachedAfter.contains(Self.ownedKey))
    }

    func testPreCheck_owned_serverTimesOut_keepsCachedAnswer() async {
        let manager = seedOwnedEntitlement()
        defer { tearDownPreCheck() }
        stubCheckEntitlement(subscriptions: [], delay: 1)

        let start = Date()
        let ids = await manager.entitledProductIdsBeforeCheckout(
            productKey: Self.ownedKey,
            refreshTimeoutMilliseconds: 50
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(ids.contains(Self.ownedKey))
        XCTAssertLessThan(elapsed, 0.5, "pre-check waited for the hung refresh instead of timing out")
        await preCheckSource.refreshEntitlementsJoiningInFlightFetch()
    }

    func testPreCheck_staleCache_joinsInFlightFetchAndKeepsStaleIdsOnTimeout() async {
        let manager = seedOwnedEntitlement()
        defer { tearDownPreCheck() }
        stubCheckEntitlement(subscriptions: [], delay: 1)
        preCheckSource.invalidateCache()
        let launchFetch = Task { [preCheckSource] in await preCheckSource!.purchasedHeliumProductIds() }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let start = Date()
        let ids = await manager.entitledProductIdsBeforeCheckout(productKey: Self.ownedKey, refreshTimeoutMilliseconds: 50)
        let elapsed = Date().timeIntervalSince(start)
        _ = await launchFetch.value

        XCTAssertTrue(ids.contains(Self.ownedKey))
        XCTAssertLessThan(elapsed, 0.5, "stale snapshot waited past the refresh timeout")
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1, "pre-check started a second fetch instead of joining the in-flight one")
        XCTAssertFalse(preCheckSource.cachedHeliumProductIds().contains(Self.ownedKey))
    }

    func testPreCheck_staleCacheNotOwned_isBoundedByTheRefreshTimeout() async {
        let manager = seedOwnedEntitlement()
        defer { tearDownPreCheck() }
        stubCheckEntitlement(subscriptions: [], delay: 1)
        preCheckSource.invalidateCache()

        let start = Date()
        let ids = await manager.entitledProductIdsBeforeCheckout(productKey: "prod_other:price_other", refreshTimeoutMilliseconds: 50)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(ids, [Self.ownedKey])
        XCTAssertLessThan(elapsed, 0.5, "stale snapshot waited past the refresh timeout")
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        await preCheckSource.refreshEntitlementsJoiningInFlightFetch()
    }

    func testPreCheck_staleCacheAfterTimeout_eligibilityReadsTheSnapshotWithoutNetwork() async {
        let manager = seedOwnedEntitlement()
        defer { tearDownPreCheck() }
        stubCheckEntitlement(subscriptions: [], delay: 1)
        preCheckSource.invalidateCache()
        _ = await manager.entitledProductIdsBeforeCheckout(productKey: "prod_other:price_other", refreshTimeoutMilliseconds: 50)

        let start = Date()
        let eligible = preCheckSource.cachedIntroOfferEligible()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(eligible, false)
        XCTAssertLessThan(elapsed, 0.5)
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        await preCheckSource.refreshEntitlementsJoiningInFlightFetch()
    }

    func testPreCheck_coldCache_waitsForTheServerAnswer() async {
        let manager = seedOwnedEntitlement(seedOwned: false)
        defer { tearDownPreCheck() }
        stubCheckEntitlement(subscriptions: [activeOwnedSubscription], delay: 1)

        let ids = await manager.entitledProductIdsBeforeCheckout(productKey: Self.ownedKey, refreshTimeoutMilliseconds: 50)

        XCTAssertTrue(ids.contains(Self.ownedKey), "cold start gave up before the subscriber's entitlement loaded")
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
    }

    func testPreCheck_afterTimedOutRefresh_nextReadDoesNotWaitForIt() async {
        let manager = seedOwnedEntitlement()
        defer { tearDownPreCheck() }
        stubCheckEntitlement(subscriptions: [], delay: 1)
        _ = await manager.entitledProductIdsBeforeCheckout(productKey: Self.ownedKey, refreshTimeoutMilliseconds: 50)

        let start = Date()
        let ids = await preCheckSource.purchasedHeliumProductIds()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(ids.contains(Self.ownedKey))
        XCTAssertLessThan(elapsed, 0.5, "a read after the timed-out refresh blocked on the still-running fetch")
        await preCheckSource.refreshEntitlementsJoiningInFlightFetch()
    }
}
