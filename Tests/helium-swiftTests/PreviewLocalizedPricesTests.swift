import XCTest
@testable import Helium

final class PreviewLocalizedPricesTests: XCTestCase {

    func testPreviewDoesNotInheritDonorWebSecondTry() throws {
        var donor = makeTestPaywallInfo()
        donor.resolvedConfig = AnyCodable(["baseStack": ["componentProps": ["bundleURL": "https://example.com/a"]]])
        donor.webSecondTryConfig = WebSecondTryConfig(
            paywallUUID: "b", paywallVersionUUID: "v", bundleUrl: "https://example.com/b",
            productsOfferedPaddle: ["pro_b:pri_b"], productsOfferedStripe: [], showOn: ["dismissed"]
        )
        let manager = HeliumFetchedConfigManager.shared
        manager.injectConfigForTesting(makeTestConfig(triggers: ["donor": donor]))
        try manager.setPreviewTriggerConfig(
            bundleId: "preview", bundleUrl: "https://example.com/preview", bundleHtml: "",
            productIds: [], productIdsStripe: [], productIdsPaddle: [], productIdsPaddleWeb: [], productIdsStripeWeb: []
        )
        XCTAssertNil(manager.getPaywallInfoForTrigger(HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER)?.webSecondTryConfig)
        XCTAssertNotNil(manager.getPaywallInfoForTrigger("donor")?.webSecondTryConfig)
    }

    func testRefreshKeysExcludeServerPricesAndKeepPromoKeys() async {
        let manager = HeliumFetchedConfigManager.shared
        let promo = "ios.product:offer"
        manager.localizedPriceMap = [
            "ios.product": makeServerPrice(formattedPrice: "$9.99").toLocalizedPrice(),
            promo: makeServerPrice(formattedPrice: "$9.99").toLocalizedPrice(),
            "pro_web:pri_web": makeServerPrice(formattedPrice: "$9.99").toLocalizedPrice(),
            "prod_web:price_web": makeServerPrice(formattedPrice: "$9.99").toLocalizedPrice(),
        ]
        var fetched: [String] = []
        await manager.refreshLocalizedPriceMap { keys in
            fetched = keys
            return [:]
        }
        XCTAssertEqual(Set(fetched), ["ios.product", promo])
        XCTAssertNotNil(manager.localizedPriceMap["pro_web:pri_web"])
        XCTAssertNotNil(manager.localizedPriceMap["prod_web:price_web"])
    }

    override func setUp() {
        super.setUp()
        HeliumFetchedConfigManager.reset()
    }

    override func tearDown() {
        HeliumFetchedConfigManager.reset()
        super.tearDown()
    }

    private func makeServerPrice(formattedPrice: String) -> ServerProductPrice {
        ServerProductPrice(
            id: "live.product",
            priceId: nil,
            formattedPrice: formattedPrice,
            localizedTitle: "Live",
            localizedDescription: nil,
            currency: "USD",
            value: 9.99,
            currencySymbol: "$",
            duration: "Month",
            productType: "subscription",
            subscriptionPeriod: "month",
            subscription: nil,
            defaultDiscountId: nil
        )
    }

    func testMissingPricesReturnsOnlyUnknownProductKeys() {
        HeliumFetchedConfigManager.shared.localizedPriceMap = [
            "live.product": makeServerPrice(formattedPrice: "$9.99").toLocalizedPrice()
        ]

        let missing = HeliumFetchedConfigManager.shared.productIdsMissingLocalizedPrices(
            ["live.product", "preview.product", "preview.product:OFFER50"]
        )
        XCTAssertEqual(missing, ["preview.product", "preview.product:OFFER50"])
    }

    func testMissingPricesEmptyWhenAllKeysKnown() {
        HeliumFetchedConfigManager.shared.localizedPriceMap = [
            "live.product": makeServerPrice(formattedPrice: "$9.99").toLocalizedPrice()
        ]

        let missing = HeliumFetchedConfigManager.shared.productIdsMissingLocalizedPrices(["live.product"])
        XCTAssertEqual(missing, [])
    }

    func testMissingPricesDedupesInput() {
        let missing = HeliumFetchedConfigManager.shared.productIdsMissingLocalizedPrices(
            ["preview.product", "preview.product"]
        )
        XCTAssertEqual(missing, ["preview.product"])
    }
}
