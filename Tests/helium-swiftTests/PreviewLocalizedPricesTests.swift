import XCTest
@testable import Helium

final class PreviewLocalizedPricesTests: XCTestCase {

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
