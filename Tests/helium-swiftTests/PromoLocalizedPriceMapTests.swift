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

    func testCompositeTriggerProductIdReturnsCompositeAndBareEntries() {
        let composite = "test_yearly:test_yearly_offer_identifier"
        let paywall = makeTestPaywallInfo(products: [composite])
        injectConfig(makeTestConfig(triggers: ["promo_trigger": paywall]))

        HeliumFetchedConfigManager.shared.setPreviewServerProducts(
            stripeProducts: [
                "test_yearly": makeServerPrice(formattedPrice: "$29.99"),
                composite: makeServerPrice(formattedPrice: "$3.99"),
            ],
            paddleProducts: nil,
            paddleClientToken: nil
        )

        let map = HeliumFetchedConfigManager.shared.getLocalizedPriceMapForTrigger("promo_trigger")
        XCTAssertEqual(map["test_yearly"]?.baseInfo.formattedPrice, "$29.99")
        XCTAssertEqual(map[composite]?.baseInfo.formattedPrice, "$3.99")
    }

    func testEachCompositeKeepsItsOwnOfferEntry() {
        // One product paired with different offers across triggers keeps both entries.
        let compositeA = "test_yearly:OFFER_A"
        let compositeB = "test_yearly:OFFER_B"
        injectConfig(makeTestConfig(triggers: [
            "trigger_a": makeTestPaywallInfo(products: [compositeA]),
            "trigger_b": makeTestPaywallInfo(products: [compositeB]),
        ]))

        HeliumFetchedConfigManager.shared.setPreviewServerProducts(
            stripeProducts: [
                "test_yearly": makeServerPrice(formattedPrice: "$29.99"),
                compositeA: makeServerPrice(formattedPrice: "$3.99"),
                compositeB: makeServerPrice(formattedPrice: "$5.99"),
            ],
            paddleProducts: nil,
            paddleClientToken: nil
        )

        let mapA = HeliumFetchedConfigManager.shared.getLocalizedPriceMapForTrigger("trigger_a")
        XCTAssertEqual(mapA[compositeA]?.baseInfo.formattedPrice, "$3.99")
        XCTAssertNil(mapA[compositeB])

        let mapB = HeliumFetchedConfigManager.shared.getLocalizedPriceMapForTrigger("trigger_b")
        XCTAssertEqual(mapB[compositeB]?.baseInfo.formattedPrice, "$5.99")
        XCTAssertNil(mapB[compositeA])
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
