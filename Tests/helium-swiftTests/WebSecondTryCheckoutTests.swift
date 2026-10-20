import XCTest
@testable import Helium

/// Covers how an external web checkout hands the web second try to its page: the flag gate, the
/// `ctx.secondTry` kill switch, and the second try's products in the checkout's other ctx blocks.
final class WebSecondTryCheckoutTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HeliumFetchedConfigManager.reset()
    }

    override func tearDown() {
        HeliumFetchedConfigManager.reset()
        super.tearDown()
    }

    private let paddleSecondTry = WebSecondTryInfo(
        paywallUUID: "pw-uuid",
        paywallVersionUUID: "pwv-uuid",
        conditions: ["dismissed"],
        productsOfferedPaddle: ["pro_st:pri_st_monthly", "pro_st:pri_st_yearly"]
    )

    private func ready() -> PaddlePrefetchOutcome {
        .ready(
            bandit: PaddleCreateTransactionForPaywallResponse(
                transactionId: "txn_st", paddleCustomerId: nil, isKnownCustomer: false, requestId: "req_st"
            ),
            paddle: PaddleTransactionCheckoutResult(rawBody: Data("{}".utf8), checkoutId: "che_st", transactionId: "txn_st")
        )
    }

    // MARK: - Flag

    func testActiveWebSecondTry_isNilWhileTheFlagIsOff() {
        var paywallInfo = makeTestPaywallInfo()
        paywallInfo.webSecondTry = paddleSecondTry

        XCTAssertNil(paywallInfo.activeWebSecondTry)
        HeliumFetchedConfigManager.shared.setFeatureFlagsForTesting(JSON(["webSecondTry": false]))
        XCTAssertNil(paywallInfo.activeWebSecondTry)
    }

    func testActiveWebSecondTry_whileTheFlagIsOn_isThePaywallsSecondTry() {
        HeliumFetchedConfigManager.shared.setFeatureFlagsForTesting(JSON(["webSecondTry": true]))
        var paywallInfo = makeTestPaywallInfo()

        XCTAssertNil(paywallInfo.activeWebSecondTry)
        paywallInfo.webSecondTry = paddleSecondTry
        XCTAssertEqual(paywallInfo.activeWebSecondTry, paddleSecondTry)
    }

    // MARK: - Kill switch

    func testStripeSecondTry_isEnabled() {
        let info = WebSecondTryInfo(paywallUUID: "pw-uuid", paywallVersionUUID: "pwv-uuid", productsOfferedStripe: ["prod_st:price_st"])

        XCTAssertTrue(WebSecondTryCheckout(info: info, provider: .stripe, paddleOutcomes: [:]).enabled)
    }

    func testPaddleSecondTry_isEnabledWhenEveryPriceIsReady() {
        let checkout = WebSecondTryCheckout(info: paddleSecondTry, provider: .paddle, paddleOutcomes: [
            "pri_st_monthly": ready(),
            "pri_st_yearly": ready(),
        ])

        XCTAssertTrue(checkout.enabled)
    }

    func testPaddleSecondTry_isDisabledWhenAnyPriceIsNotReady() {
        let notReady: [PaddlePrefetchOutcome] = [
            .failed(error: PaddlePrefetchAwaitTimeout(priceId: "pri_st_yearly", timeout: 3)),
            .alreadyEntitled(code: "duplicate_subscription", message: "Already owned", existingSubscriptionId: nil),
            .notStarted,
        ]
        for outcome in notReady {
            let checkout = WebSecondTryCheckout(info: paddleSecondTry, provider: .paddle, paddleOutcomes: [
                "pri_st_monthly": ready(),
                "pri_st_yearly": outcome,
            ])

            XCTAssertFalse(checkout.enabled, "\(outcome)")
        }

        let neverPrefetched = WebSecondTryCheckout(info: paddleSecondTry, provider: .paddle, paddleOutcomes: [
            "pri_st_monthly": ready(),
        ])
        XCTAssertFalse(neverPrefetched.enabled)
    }

    func testPaddleSecondTry_withoutAUsablePrice_isDisabled() {
        for products in [nil, [], ["not_a_composite"]] as [[String]?] {
            var info = paddleSecondTry
            info.productsOfferedPaddle = products

            XCTAssertFalse(
                WebSecondTryCheckout(info: info, provider: .paddle, paddleOutcomes: ["not_a_composite": ready()]).enabled,
                "\(String(describing: products))"
            )
        }
    }

    // MARK: - ctx

    func testCtx_carriesTheSwitchIdsAndConditions() {
        let checkout = WebSecondTryCheckout(info: paddleSecondTry, provider: .paddle, paddleOutcomes: [
            "pri_st_monthly": ready(),
            "pri_st_yearly": ready(),
        ])

        XCTAssertEqual(checkout.ctx as NSDictionary, [
            "enabled": true,
            "paywallUUID": "pw-uuid",
            "paywallVersionUUID": "pwv-uuid",
            "conditions": ["dismissed"],
        ])
    }

    func testCtx_whileDisabled_stillIdentifiesTheSecondTry() {
        let checkout = WebSecondTryCheckout(info: paddleSecondTry, provider: .paddle, paddleOutcomes: [:])

        XCTAssertEqual(checkout.ctx as NSDictionary, [
            "enabled": false,
            "paywallUUID": "pw-uuid",
            "paywallVersionUUID": "pwv-uuid",
            "conditions": ["dismissed"],
        ])
    }

    /// The page uses the conditions compiled into its bundle when ctx carries none, and treats an
    /// empty list as allowing no condition.
    func testCtx_passesConditionsThroughOnlyWhenTheServerSentThem() {
        var info = WebSecondTryInfo(paywallUUID: "pw-uuid", paywallVersionUUID: "pwv-uuid", productsOfferedStripe: ["prod_st:price_st"])
        XCTAssertNil(WebSecondTryCheckout(info: info, provider: .stripe, paddleOutcomes: [:]).ctx["conditions"])

        info.conditions = []
        XCTAssertEqual(WebSecondTryCheckout(info: info, provider: .stripe, paddleOutcomes: [:]).ctx["conditions"] as? [String], [])
    }

    func testPaddleBootstrapOutcomes_areTheSecondTrysPricesOnlyWhileEnabled() {
        let outcomes: [String: PaddlePrefetchOutcome] = [
            "pri_st_monthly": ready(),
            "pri_st_yearly": ready(),
            "pri_unrelated": ready(),
        ]

        let enabled = WebSecondTryCheckout(info: paddleSecondTry, provider: .paddle, paddleOutcomes: outcomes)
        XCTAssertEqual(Set(enabled.paddleBootstrapOutcomes.keys), ["pri_st_monthly", "pri_st_yearly"])

        let disabled = WebSecondTryCheckout(info: paddleSecondTry, provider: .paddle, paddleOutcomes: ["pri_st_monthly": ready()])
        XCTAssertTrue(disabled.paddleBootstrapOutcomes.isEmpty)

        let stripe = WebSecondTryCheckout(info: paddleSecondTry, provider: .stripe, paddleOutcomes: outcomes)
        XCTAssertTrue(stripe.paddleBootstrapOutcomes.isEmpty)
    }

    // MARK: - Products

    func testPurchasableProducts_areTheProvidersSecondTryProductsWhileEnabled() {
        let info = WebSecondTryInfo(
            paywallUUID: "pw-uuid",
            paywallVersionUUID: "pwv-uuid",
            productsOfferedPaddle: ["pro_st:pri_st"],
            productsOfferedStripe: ["prod_st:price_st"]
        )

        XCTAssertEqual(WebSecondTryCheckout(info: info, provider: .stripe, paddleOutcomes: [:]).purchasableProducts, ["prod_st:price_st"])
        XCTAssertEqual(WebSecondTryCheckout(info: info, provider: .paddle, paddleOutcomes: ["pri_st": ready()]).purchasableProducts, ["pro_st:pri_st"])
        XCTAssertEqual(WebSecondTryCheckout(info: info, provider: .paddle, paddleOutcomes: [:]).purchasableProducts, [])
    }

    // MARK: - Stripe offer terms

    private func stripeSubscription(trialDays: Int?) throws -> ServerProductPrice {
        var subscription: [String: Any] = [
            "periodUnit": "month", "periodValue": 1, "introOfferEligible": trialDays != nil,
        ]
        if let trialDays {
            subscription["introOffers"] = [[
                "type": "IntroOffer", "paymentMode": "FreeTrial",
                "periodUnit": "day", "periodValue": trialDays, "periodCount": 1,
            ]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["subscription": subscription])
        return try JSONDecoder().decode(ServerProductPrice.self, from: data)
    }

    func testStripeOfferTerms_includeTheSecondTrysProductsWhenGiven() throws {
        var config = makeTestConfig(triggers: [:])
        config.stripeProducts = [
            "prod_main:price_main": try stripeSubscription(trialDays: nil),
            "prod_st:price_st": try stripeSubscription(trialDays: 7),
        ]
        injectConfig(config)
        var paywallInfo = makeTestPaywallInfo()
        paywallInfo.webProductsOfferedStripe = ["prod_main:price_main"]
        let manager = ExternalWebCheckoutManager(
            provider: .stripe,
            entitlementsSource: HeliumPaymentEntitlementsSource(provider: .stripe)
        )

        let withSecondTry = try XCTUnwrap(
            manager.buildStripeOfferTerms(paywallInfo: paywallInfo, secondTryProducts: ["prod_st:price_st"])
        )
        XCTAssertEqual(Set(withSecondTry.keys), ["prod_main:price_main", "prod_st:price_st"])
        let secondTryTerms = try XCTUnwrap(withSecondTry["prod_st:price_st"] as? [String: Any])
        XCTAssertEqual((secondTryTerms["introOffer"] as? [String: Any])?["periodValue"] as? Int, 7)

        let primaryOnly = try XCTUnwrap(manager.buildStripeOfferTerms(paywallInfo: paywallInfo))
        XCTAssertEqual(Set(primaryOnly.keys), ["prod_main:price_main"])
    }

    // MARK: - Purchase detection

    /// Entitlements as successive purchase checks read them, the last repeating, as when a
    /// purchase's webhook lands between checks.
    private final class StubEntitlementsSource: HeliumPaymentEntitlementsSource, @unchecked Sendable {
        private let lock = NSLock()
        private let entitledIdsByCheck: [Set<String>]
        private var checks = 0

        init(provider: PaymentProviderConfig, entitledIdsByCheck: [Set<String>]) {
            self.entitledIdsByCheck = entitledIdsByCheck
            super.init(provider: provider)
        }

        override func refreshEntitlements() async {}

        override func purchasedHeliumProductIds() async -> Set<String> {
            lock.withLock {
                defer { checks += 1 }
                return entitledIdsByCheck[min(checks, entitledIdsByCheck.count - 1)]
            }
        }
    }

    /// Runs the purchase checks a success redirect makes for one checkout and returns the events
    /// its session received.
    @MainActor
    private func eventsAfterSuccessRedirect(
        provider: PaymentProviderConfig,
        paywallInfo: HeliumPaywallInfo,
        entitledIdsByCheck: [Set<String>],
        entitledBeforeCheckout: Set<String>,
        secondTryProducts: [String]
    ) async throws -> [PaywallContextEvent] {
        let captor = PaywallEventHandlersCaptor()
        let manager = ExternalWebCheckoutManager(
            provider: provider,
            entitlementsSource: StubEntitlementsSource(provider: provider, entitledIdsByCheck: entitledIdsByCheck)
        )
        manager.addObservation(
            paywallSession: makeTestSession(eventHandlers: captor.handlers, paywallInfo: paywallInfo),
            entitledProductIdsBeforeCheckout: entitledBeforeCheckout,
            secondTryProducts: secondTryProducts
        )

        await manager.handleExternalReturn(redirectKind: .success)
        // Session handlers receive events on a later main-actor turn.
        let deadline = Date().addingTimeInterval(2)
        while captor.anyEvents.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return captor.anyEvents
    }

    /// A purchase made in the second try's page lands as an entitlement to one of its products,
    /// which the paywall's own offered set doesn't contain.
    @MainActor
    func testSuccessRedirect_attributesAPurchaseOfTheSecondTrysProduct() async throws {
        var paywallInfo = makeTestPaywallInfo()
        paywallInfo.webProductsOfferedPaddle = ["pro_main:pri_main"]

        let events = try await eventsAfterSuccessRedirect(
            provider: .paddle,
            paywallInfo: paywallInfo,
            entitledIdsByCheck: [["pro_unrelated:pri_unrelated", "pro_st:pri_st"]],
            entitledBeforeCheckout: [],
            secondTryProducts: ["pro_st:pri_st"]
        )

        let succeeded = events.compactMap { $0 as? PurchaseSucceededEvent }
        XCTAssertEqual(succeeded.map(\.productId), ["pro_st:pri_st"])
        XCTAssertEqual(succeeded.first?.paymentProcessor, .paddle)
    }

    /// A redirect's first check can run before the new purchase's webhook lands. A second-try
    /// product the user already owned must not pass for a restore there, which would end the
    /// checks before the purchase shows up.
    @MainActor
    func testSuccessRedirect_ownedSecondTryProduct_doesNotPreemptTheNewPurchase() async throws {
        var paywallInfo = makeTestPaywallInfo()
        paywallInfo.webProductsOfferedStripe = ["prod_main:price_y"]

        let events = try await eventsAfterSuccessRedirect(
            provider: .stripe,
            paywallInfo: paywallInfo,
            entitledIdsByCheck: [["prod_st:price_x"], ["prod_st:price_x", "prod_main:price_y"]],
            entitledBeforeCheckout: ["prod_st:price_x"],
            secondTryProducts: ["prod_st:price_x"]
        )

        XCTAssertEqual(events.compactMap { ($0 as? PurchaseSucceededEvent)?.productId }, ["prod_main:price_y"])
        XCTAssertFalse(events.contains { $0 is PurchaseRestoredEvent }, "\(events.map(\.eventName))")
    }

    /// While the page couldn't show the second try, an entitlement to one of its products didn't
    /// come from this checkout.
    @MainActor
    func testSuccessRedirect_doesNotCountADisabledSecondTrysProducts() async throws {
        let disabled = WebSecondTryCheckout(info: paddleSecondTry, provider: .paddle, paddleOutcomes: [:])
        XCTAssertFalse(disabled.enabled)
        var paywallInfo = makeTestPaywallInfo()
        paywallInfo.webProductsOfferedPaddle = ["pro_main:pri_main"]

        let events = try await eventsAfterSuccessRedirect(
            provider: .paddle,
            paywallInfo: paywallInfo,
            entitledIdsByCheck: [["pro_st:pri_st_monthly"], ["pro_st:pri_st_monthly", "pro_main:pri_main"]],
            entitledBeforeCheckout: [],
            secondTryProducts: disabled.purchasableProducts
        )

        XCTAssertEqual(events.compactMap { ($0 as? PurchaseSucceededEvent)?.productId }, ["pro_main:pri_main"])
    }
}
