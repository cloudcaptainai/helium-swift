import XCTest
@testable import Helium

final class ProductLocalizationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        Helium.resetHelium()
    }

    override func tearDown() {
        Helium.resetHelium()
        super.tearDown()
    }

    func testLocalizedPriceJsonSerialization() {
        let price = LocalizedPrice(
            baseInfo: BasePriceInfo(
                currency: "USD",
                locale: "en_US",
                value: 9.99,
                formattedPrice: "$9.99",
                currencySymbol: "$",
                decimalSeparator: "."
            ),
            productType: "autoRenewable",
            localizedTitle: "Premium Monthly",
            localizedDescription: "Get premium features",
            displayName: "Premium",
            description: "Monthly premium subscription",
            subscriptionInfo: SubscriptionInfo(
                periodUnit: "month",
                periodValue: 1,
                introOfferEligible: true,
                introOffer: SubscriptionOffer(
                    type: "introductory",
                    price: 0,
                    displayPrice: "Free",
                    periodUnit: "week",
                    periodValue: 1,
                    periodCount: 1,
                    paymentMode: "freeTrial"
                )
            ),
            iapInfo: nil,
            familyShareable: false
        )

        let json = price.json
        XCTAssertEqual(json["currency"] as? String, "USD")
        XCTAssertEqual(json["locale"] as? String, "en_US")
        XCTAssertEqual(json["formattedPrice"] as? String, "$9.99")
        XCTAssertEqual(json["currencySymbol"] as? String, "$")
        XCTAssertEqual(json["productType"] as? String, "autoRenewable")
        XCTAssertEqual(json["localizedTitle"] as? String, "Premium Monthly")
        XCTAssertEqual(json["familyShareable"] as? Bool, false)
    }

    func testSubscriptionInfoInJson() {
        let price = LocalizedPrice(
            baseInfo: BasePriceInfo(
                currency: "USD",
                locale: "en_US",
                value: 4.99,
                formattedPrice: "$4.99",
                currencySymbol: "$",
                decimalSeparator: "."
            ),
            productType: "autoRenewable",
            localizedTitle: nil,
            localizedDescription: nil,
            displayName: nil,
            description: nil,
            subscriptionInfo: SubscriptionInfo(
                periodUnit: "month",
                periodValue: 1,
                introOfferEligible: false,
                introOffer: nil
            ),
            iapInfo: nil,
            familyShareable: true
        )

        let json = price.json
        let subscription = json["subscription"] as? [String: Any]
        XCTAssertNotNil(subscription)
        XCTAssertEqual(subscription?["periodUnit"] as? String, "month")
        XCTAssertEqual(subscription?["periodValue"] as? Int, 1)
        XCTAssertEqual(subscription?["introOfferEligible"] as? Bool, false)
    }

    func testGetLocalizedPriceMapReturnsEmptyAfterReset() {
        HeliumFetchedConfigManager.reset()
        let map = HeliumFetchedConfigManager.shared.getLocalizedPriceMap()
        XCTAssertTrue(map.isEmpty)
    }

    func testBasePriceInfoCodable() throws {
        let original = BasePriceInfo(
            currency: "EUR",
            locale: "de_DE",
            value: 12.99,
            formattedPrice: "12,99 €",
            currencySymbol: "€",
            decimalSeparator: ","
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BasePriceInfo.self, from: data)
        XCTAssertEqual(decoded.currency, "EUR")
        XCTAssertEqual(decoded.locale, "de_DE")
        XCTAssertEqual(decoded.value, 12.99)
        XCTAssertEqual(decoded.formattedPrice, "12,99 €")
        XCTAssertEqual(decoded.currencySymbol, "€")
        XCTAssertEqual(decoded.decimalSeparator, ",")
    }
}
