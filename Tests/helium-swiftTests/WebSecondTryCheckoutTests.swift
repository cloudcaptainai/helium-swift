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
}
