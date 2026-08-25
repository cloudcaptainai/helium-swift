import XCTest
@testable import Helium

final class PreviewServerProductsTests: XCTestCase {

    private let stripeKey = "prod_preview:price_preview"
    private let paddleKey = "pro_preview:pri_preview"
    private let liveKey = "prod_live:price_live"

    override func setUp() {
        super.setUp()
        HeliumFetchedConfigManager.reset()
    }

    override func tearDown() {
        HeliumFetchedConfigManager.reset()
        super.tearDown()
    }

    private func makeServerPrice(
        formattedPrice: String,
        value: Decimal,
        title: String = "Preview Monthly"
    ) -> ServerProductPrice {
        ServerProductPrice(
            id: "prod_preview",
            priceId: "price_preview",
            formattedPrice: formattedPrice,
            localizedTitle: title,
            localizedDescription: nil,
            currency: "USD",
            value: value,
            currencySymbol: "$",
            duration: "Month",
            productType: "subscription",
            subscriptionPeriod: "month",
            subscription: nil,
            defaultDiscountId: nil
        )
    }

    private func injectBaseConfig(
        stripeProducts: [String: ServerProductPrice]? = nil,
        paddleProducts: [String: ServerProductPrice]? = nil,
        paddleClientToken: String? = nil
    ) {
        var config = makeTestConfig(triggers: ["live_trigger": makeTestPaywallInfo()])
        config.stripeProducts = stripeProducts
        config.paddleProducts = paddleProducts
        config.paddleClientToken = paddleClientToken
        injectConfig(config)
    }

    func testPreviewProductsSurfaceThroughTheProductMaps() {
        injectBaseConfig()

        HeliumFetchedConfigManager.shared.setPreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99)],
            paddleProducts: [paddleKey: makeServerPrice(formattedPrice: "$19.99", value: 19.99)],
            paddleClientToken: "preview_token"
        )

        XCTAssertNotNil(HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()?[stripeKey])
        XCTAssertNotNil(HeliumFetchedConfigManager.shared.getPaddleProductsPriceMap()?[paddleKey])
        XCTAssertEqual(HeliumFetchedConfigManager.shared.paddleClientToken, "preview_token")

        let priceMap = HeliumFetchedConfigManager.shared.getLocalizedPriceMap()
        XCTAssertEqual(priceMap[stripeKey]?.baseInfo.formattedPrice, "$9.99")
        XCTAssertEqual(priceMap[paddleKey]?.baseInfo.formattedPrice, "$19.99")
    }

    func testPreviewNeverEntersTheFetchedConfig() {
        injectBaseConfig()

        HeliumFetchedConfigManager.shared.setPreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99)],
            paddleProducts: [paddleKey: makeServerPrice(formattedPrice: "$19.99", value: 19.99)],
            paddleClientToken: "preview_token"
        )

        XCTAssertNil(HeliumFetchedConfigManager.shared.fetchedConfig?.stripeProducts?[stripeKey])
        XCTAssertNil(HeliumFetchedConfigManager.shared.fetchedConfig?.paddleProducts?[paddleKey])
        XCTAssertNil(HeliumFetchedConfigManager.shared.fetchedConfig?.paddleClientToken)
    }

    func testLiveValuesWinOverPreviewValues() {
        injectBaseConfig(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$4.99", value: 4.99, title: "Live")],
            paddleClientToken: "live_token"
        )

        HeliumFetchedConfigManager.shared.setPreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99, title: "Preview")],
            paddleProducts: nil,
            paddleClientToken: "preview_token"
        )

        XCTAssertEqual(HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()?[stripeKey]?.localizedTitle, "Live")
        XCTAssertEqual(HeliumFetchedConfigManager.shared.paddleClientToken, "live_token")
    }

    func testLiveValuesWinEvenWhenThePreviewArrivedFirst() {
        HeliumFetchedConfigManager.shared.setPreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99, title: "Preview")],
            paddleProducts: nil,
            paddleClientToken: "preview_token"
        )

        injectBaseConfig(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$4.99", value: 4.99, title: "Live")],
            paddleClientToken: "live_token"
        )

        XCTAssertEqual(HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()?[stripeKey]?.localizedTitle, "Live")
        XCTAssertEqual(HeliumFetchedConfigManager.shared.paddleClientToken, "live_token")
    }

    func testPreviewFillsOnlyTheKeysLiveDoesNotCarry() {
        injectBaseConfig(stripeProducts: [liveKey: makeServerPrice(formattedPrice: "$4.99", value: 4.99, title: "Live")])

        HeliumFetchedConfigManager.shared.setPreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99)],
            paddleProducts: nil,
            paddleClientToken: nil
        )

        let map = HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()
        XCTAssertEqual(map?[liveKey]?.localizedTitle, "Live")
        XCTAssertNotNil(map?[stripeKey])
    }

    func testRefreshReplacesEarlierPreviewValues() {
        injectBaseConfig()

        HeliumFetchedConfigManager.shared.setPreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99, title: "Before")],
            paddleProducts: nil,
            paddleClientToken: "first_token"
        )
        HeliumFetchedConfigManager.shared.setPreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$14.99", value: 14.99, title: "After")],
            paddleProducts: nil,
            paddleClientToken: "second_token"
        )

        XCTAssertEqual(HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()?[stripeKey]?.localizedTitle, "After")
        XCTAssertEqual(
            HeliumFetchedConfigManager.shared.getLocalizedPriceMap()[stripeKey]?.baseInfo.formattedPrice,
            "$14.99"
        )
        XCTAssertEqual(HeliumFetchedConfigManager.shared.paddleClientToken, "second_token")
    }

    func testMissingClientTokenIsSuppliedByThePreview() {
        injectBaseConfig(paddleClientToken: nil)

        HeliumFetchedConfigManager.shared.setPreviewServerProducts(
            stripeProducts: nil,
            paddleProducts: [paddleKey: makeServerPrice(formattedPrice: "$19.99", value: 19.99)],
            paddleClientToken: "preview_token"
        )

        XCTAssertEqual(HeliumFetchedConfigManager.shared.paddleClientToken, "preview_token")
    }

    func testEmptyPreviewLeavesLiveValuesIntact() {
        injectBaseConfig(
            stripeProducts: [liveKey: makeServerPrice(formattedPrice: "$4.99", value: 4.99, title: "Live")],
            paddleClientToken: "live_token"
        )

        HeliumFetchedConfigManager.shared.setPreviewServerProducts(
            stripeProducts: nil,
            paddleProducts: nil,
            paddleClientToken: nil
        )

        XCTAssertEqual(HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()?[liveKey]?.localizedTitle, "Live")
        XCTAssertNil(HeliumFetchedConfigManager.shared.getPaddleProductsPriceMap())
        XCTAssertEqual(HeliumFetchedConfigManager.shared.paddleClientToken, "live_token")
    }

    private func makeResponse(
        stripe: [String: ServerProductPrice]? = nil,
        paddleClientToken: String? = nil
    ) -> HeliumControlPanelResponse {
        HeliumControlPanelResponse(
            productIds: [],
            paywalls: [],
            stripeProducts: stripe,
            paddleProducts: nil,
            paddleClientToken: paddleClientToken,
            forceExternalCheckoutSimulation: nil
        )
    }

    func testCanceledRefreshDoesNotApplyItsProducts() async {
        injectBaseConfig()
        let response = makeResponse(
            stripe: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99)],
            paddleClientToken: "stale_token"
        )

        let task = Task { () -> Bool in
            // Cancellation lands during this sleep, so the call below always sees it.
            try? await Task.sleep(nanoseconds: 50_000_000)
            return HeliumControlPanelService.shared.applyServerProducts(from: response)
        }
        task.cancel()
        let applied = await task.value

        XCTAssertFalse(applied)
        XCTAssertNil(HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()?[stripeKey])
        XCTAssertNil(HeliumFetchedConfigManager.shared.paddleClientToken)
    }

    func testOverlappingRefreshKeepsTheNewerResponse() async {
        injectBaseConfig()
        let stale = makeResponse(
            stripe: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99, title: "Stale")],
            paddleClientToken: "stale_token"
        )
        let fresh = makeResponse(
            stripe: [stripeKey: makeServerPrice(formattedPrice: "$14.99", value: 14.99, title: "Fresh")],
            paddleClientToken: "fresh_token"
        )

        let freshTask = Task { HeliumControlPanelService.shared.applyServerProducts(from: fresh) }
        _ = await freshTask.value

        // The canceled refresh resolves last; its products must not displace the newer ones.
        let staleTask = Task { () -> Bool in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return HeliumControlPanelService.shared.applyServerProducts(from: stale)
        }
        staleTask.cancel()
        _ = await staleTask.value

        XCTAssertEqual(HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()?[stripeKey]?.localizedTitle, "Fresh")
        XCTAssertEqual(HeliumFetchedConfigManager.shared.paddleClientToken, "fresh_token")
    }

    func testPreviewWithNoConfigDoesNotCrash() {
        HeliumFetchedConfigManager.shared.setPreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99)],
            paddleProducts: nil,
            paddleClientToken: "preview_token"
        )

        XCTAssertNil(HeliumFetchedConfigManager.shared.fetchedConfig)
        XCTAssertNotNil(HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()?[stripeKey])
        XCTAssertEqual(
            HeliumFetchedConfigManager.shared.getLocalizedPriceMap()[stripeKey]?.baseInfo.formattedPrice,
            "$9.99"
        )
    }
}
