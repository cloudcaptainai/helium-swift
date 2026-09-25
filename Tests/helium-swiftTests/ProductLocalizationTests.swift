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

    private func makePriceWithSubscription(_ subscriptionInfo: SubscriptionInfo) -> LocalizedPrice {
        LocalizedPrice(
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
            subscriptionInfo: subscriptionInfo,
            iapInfo: nil,
            familyShareable: false
        )
    }

    func testPromoOfferSerialization() {
        let price = makePriceWithSubscription(SubscriptionInfo(
            periodUnit: "year",
            periodValue: 1,
            introOfferEligible: false,
            introOffer: nil,
            promoOfferEligible: true,
            promoOffer: PromotionalOfferInfo(
                offerId: "test_yearly_offer_identifier",
                type: "promotional",
                price: 3.99,
                displayPrice: "$3.99",
                periodUnit: "week",
                periodValue: 1,
                periodCount: 1,
                paymentMode: "payAsYouGo"
            )
        ))

        let subscription = price.json["subscription"] as? [String: Any]
        XCTAssertEqual(subscription?["promoOfferEligible"] as? Bool, true)
        let promoOffer = subscription?["promoOffer"] as? [String: Any]
        XCTAssertEqual(promoOffer?["offerId"] as? String, "test_yearly_offer_identifier")
        XCTAssertEqual(promoOffer?["type"] as? String, "promotional")
        XCTAssertEqual(promoOffer?["displayPrice"] as? String, "$3.99")
        XCTAssertEqual(promoOffer?["periodUnit"] as? String, "week")
        XCTAssertEqual(promoOffer?["paymentMode"] as? String, "payAsYouGo")
    }

    func testNilPromoFieldsAreAbsentFromJson() {
        let price = makePriceWithSubscription(SubscriptionInfo(
            periodUnit: "month",
            periodValue: 1,
            introOfferEligible: false,
            introOffer: nil
        ))

        let subscription = price.json["subscription"] as? [String: Any]
        XCTAssertNil(subscription?["promoOfferEligible"])
        XCTAssertNil(subscription?["promoOffer"])
    }

    func testIntroAndPromoEligibilitySerializeIndependently() {
        let introTruePromoFalse = makePriceWithSubscription(SubscriptionInfo(
            periodUnit: "month",
            periodValue: 1,
            introOfferEligible: true,
            introOffer: nil,
            promoOfferEligible: false,
            promoOffer: nil
        ))
        var subscription = introTruePromoFalse.json["subscription"] as? [String: Any]
        XCTAssertEqual(subscription?["introOfferEligible"] as? Bool, true)
        XCTAssertEqual(subscription?["promoOfferEligible"] as? Bool, false)

        let introFalsePromoTrue = makePriceWithSubscription(SubscriptionInfo(
            periodUnit: "month",
            periodValue: 1,
            introOfferEligible: false,
            introOffer: nil,
            promoOfferEligible: true,
            promoOffer: nil
        ))
        subscription = introFalsePromoTrue.json["subscription"] as? [String: Any]
        XCTAssertEqual(subscription?["introOfferEligible"] as? Bool, false)
        XCTAssertEqual(subscription?["promoOfferEligible"] as? Bool, true)
    }

    func testPromotionalOfferInfoCodableRoundTrip() throws {
        let original = PromotionalOfferInfo(
            offerId: "OFFER50",
            type: "promotional",
            price: 3.99,
            displayPrice: "$3.99",
            periodUnit: "month",
            periodValue: 3,
            periodCount: 1,
            paymentMode: "payUpFront"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PromotionalOfferInfo.self, from: data)
        XCTAssertEqual(decoded.offerId, "OFFER50")
        XCTAssertEqual(decoded.type, "promotional")
        XCTAssertEqual(decoded.price, 3.99)
        XCTAssertEqual(decoded.displayPrice, "$3.99")
        XCTAssertEqual(decoded.periodUnit, "month")
        XCTAssertEqual(decoded.periodValue, 3)
        XCTAssertEqual(decoded.periodCount, 1)
        XCTAssertEqual(decoded.paymentMode, "payUpFront")
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
