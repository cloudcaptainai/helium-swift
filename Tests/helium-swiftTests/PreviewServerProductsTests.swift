import XCTest
@testable import Helium

final class PreviewServerProductsTests: XCTestCase {

    private let stripeKey = "prod_preview:price_preview"
    private let paddleKey = "pro_preview:pri_preview"

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

    func testPreviewProductsLandInConfigAndPriceMap() {
        injectBaseConfig()

        HeliumFetchedConfigManager.shared.mergePreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99)],
            paddleProducts: [paddleKey: makeServerPrice(formattedPrice: "$19.99", value: 19.99)],
            paddleClientToken: "live_abc123"
        )

        XCTAssertNotNil(HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()?[stripeKey])
        XCTAssertNotNil(HeliumFetchedConfigManager.shared.getPaddleProductsPriceMap()?[paddleKey])
        XCTAssertEqual(HeliumFetchedConfigManager.shared.fetchedConfig?.paddleClientToken, "live_abc123")

        let priceMap = HeliumFetchedConfigManager.shared.getLocalizedPriceMap()
        XCTAssertEqual(priceMap[stripeKey]?.baseInfo.formattedPrice, "$9.99")
        XCTAssertEqual(priceMap[paddleKey]?.baseInfo.formattedPrice, "$19.99")
    }

    func testExistingConfigValuesAreNotOverwritten() {
        injectBaseConfig(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$4.99", value: 4.99, title: "Live")],
            paddleClientToken: "live_existing"
        )

        HeliumFetchedConfigManager.shared.mergePreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99, title: "Preview")],
            paddleProducts: nil,
            paddleClientToken: "preview_token"
        )

        XCTAssertEqual(HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()?[stripeKey]?.localizedTitle, "Live")
        XCTAssertEqual(HeliumFetchedConfigManager.shared.fetchedConfig?.paddleClientToken, "live_existing")
    }

    func testNewKeysAreAddedAlongsideExistingOnes() {
        let liveKey = "prod_live:price_live"
        injectBaseConfig(stripeProducts: [liveKey: makeServerPrice(formattedPrice: "$4.99", value: 4.99)])

        HeliumFetchedConfigManager.shared.mergePreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99)],
            paddleProducts: nil,
            paddleClientToken: nil
        )

        let map = HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()
        XCTAssertNotNil(map?[liveKey])
        XCTAssertNotNil(map?[stripeKey])
    }

    func testMissingClientTokenIsFilledIn() {
        injectBaseConfig(paddleClientToken: nil)

        HeliumFetchedConfigManager.shared.mergePreviewServerProducts(
            stripeProducts: nil,
            paddleProducts: [paddleKey: makeServerPrice(formattedPrice: "$19.99", value: 19.99)],
            paddleClientToken: "preview_token"
        )

        XCTAssertEqual(HeliumFetchedConfigManager.shared.fetchedConfig?.paddleClientToken, "preview_token")
    }

    func testEmptyResponseLeavesConfigUntouched() {
        injectBaseConfig(paddleClientToken: "live_existing")

        HeliumFetchedConfigManager.shared.mergePreviewServerProducts(
            stripeProducts: nil,
            paddleProducts: nil,
            paddleClientToken: nil
        )

        XCTAssertNil(HeliumFetchedConfigManager.shared.getStripeProductsPriceMap())
        XCTAssertNil(HeliumFetchedConfigManager.shared.getPaddleProductsPriceMap())
        XCTAssertEqual(HeliumFetchedConfigManager.shared.fetchedConfig?.paddleClientToken, "live_existing")
    }

    func testRefreshReplacesValuesAnEarlierPreviewMergeInstalled() {
        injectBaseConfig(
            stripeProducts: ["prod_live:price_live": makeServerPrice(formattedPrice: "$4.99", value: 4.99, title: "Live")]
        )

        HeliumFetchedConfigManager.shared.mergePreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99, title: "Before")],
            paddleProducts: nil,
            paddleClientToken: "first_token"
        )

        HeliumFetchedConfigManager.shared.mergePreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$14.99", value: 14.99, title: "After")],
            paddleProducts: nil,
            paddleClientToken: "second_token"
        )

        let map = HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()
        XCTAssertEqual(map?[stripeKey]?.localizedTitle, "After")
        XCTAssertEqual(map?[stripeKey]?.formattedPrice, "$14.99")
        XCTAssertEqual(
            HeliumFetchedConfigManager.shared.getLocalizedPriceMap()[stripeKey]?.baseInfo.formattedPrice,
            "$14.99"
        )
        XCTAssertEqual(HeliumFetchedConfigManager.shared.fetchedConfig?.paddleClientToken, "second_token")

        XCTAssertEqual(map?["prod_live:price_live"]?.localizedTitle, "Live")
    }

    func testNewConfigEndsPreviewOwnership() {
        HeliumFetchedConfigManager.shared.mergePreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99, title: "Preview")],
            paddleProducts: nil,
            paddleClientToken: nil
        )

        injectBaseConfig(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$4.99", value: 4.99, title: "Live")]
        )

        HeliumFetchedConfigManager.shared.mergePreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$19.99", value: 19.99, title: "Preview2")],
            paddleProducts: nil,
            paddleClientToken: nil
        )

        XCTAssertEqual(HeliumFetchedConfigManager.shared.getStripeProductsPriceMap()?[stripeKey]?.localizedTitle, "Live")
    }

    func testMergeWithNoConfigDoesNotCrash() {
        HeliumFetchedConfigManager.shared.mergePreviewServerProducts(
            stripeProducts: [stripeKey: makeServerPrice(formattedPrice: "$9.99", value: 9.99)],
            paddleProducts: nil,
            paddleClientToken: "preview_token"
        )

        XCTAssertNil(HeliumFetchedConfigManager.shared.fetchedConfig)
        XCTAssertEqual(HeliumFetchedConfigManager.shared.getLocalizedPriceMap()[stripeKey]?.baseInfo.formattedPrice, "$9.99")
    }
}
