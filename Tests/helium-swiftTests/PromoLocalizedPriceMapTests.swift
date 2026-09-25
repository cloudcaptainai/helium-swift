import XCTest
@testable import Helium

final class PromoLocalizedPriceMapTests: XCTestCase {

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
            id: "test_yearly",
            priceId: nil,
            formattedPrice: formattedPrice,
            localizedTitle: "Yearly",
            localizedDescription: nil,
            currency: "USD",
            value: 29.99,
            currencySymbol: "$",
            duration: "Year",
            productType: "subscription",
            subscriptionPeriod: "year",
            subscription: nil,
            defaultDiscountId: nil
        )
    }

    func testCompositeTriggerProductIdMatchesBareIdPriceMapEntry() {
        // Preview prices overlay into getLocalizedPriceMap keyed by bare product id;
        // the trigger's product list carries the composite key.
        let paywall = makeTestPaywallInfo(products: ["test_yearly:test_yearly_offer_identifier"])
        injectConfig(makeTestConfig(triggers: ["promo_trigger": paywall]))

        HeliumFetchedConfigManager.shared.setPreviewServerProducts(
            stripeProducts: ["test_yearly": makeServerPrice(formattedPrice: "$29.99")],
            paddleProducts: nil,
            paddleClientToken: nil
        )

        let map = HeliumFetchedConfigManager.shared.getLocalizedPriceMapForTrigger("promo_trigger")
        XCTAssertEqual(map["test_yearly"]?.baseInfo.formattedPrice, "$29.99")
    }

    func testBareTriggerProductIdStillMatches() {
        let paywall = makeTestPaywallInfo(products: ["test_yearly"])
        injectConfig(makeTestConfig(triggers: ["plain_trigger": paywall]))

        HeliumFetchedConfigManager.shared.setPreviewServerProducts(
            stripeProducts: ["test_yearly": makeServerPrice(formattedPrice: "$29.99")],
            paddleProducts: nil,
            paddleClientToken: nil
        )

        let map = HeliumFetchedConfigManager.shared.getLocalizedPriceMapForTrigger("plain_trigger")
        XCTAssertEqual(map["test_yearly"]?.baseInfo.formattedPrice, "$29.99")
    }
}
