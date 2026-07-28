import XCTest
@testable import Helium

/// Covers the price-map derivation used when `/check-entitlement` returns no
/// eligibility value. Fixtures are decoded from the on-launch wire shape rather
/// than hand-constructed, so a rename on the server side surfaces here.
final class WebCheckoutIntroOfferEligibilityTests: XCTestCase {

    /// The shapes bandit emits for a price.
    private enum Shape {
        /// Trial configured and this customer may have it: flag true, offer present.
        case eligibleTrial
        /// Trial configured but already consumed: flag false, offer omitted.
        case consumedTrial
        /// No trial on the price at all: flag false, offer omitted. Identical on
        /// the wire to `consumedTrial`, which is why offer-bearing is the test.
        case noTrial
        /// One-time product: no subscription block.
        case oneTime
        /// Not a shape bandit emits today. Pins that an offer-bearing price
        /// reporting ineligible still fails the check.
        case offerButIneligible
    }

    private func price(_ productKey: String, _ shape: Shape) throws -> ServerProductPrice {
        let parts = productKey.split(separator: ":")
        var json: [String: Any] = [
            "id": String(parts[0]),
            "priceId": String(parts[1]),
            "formattedPrice": "$29.99",
            "currency": "USD",
            "productType": shape == .oneTime ? "one_time" : "subscription",
        ]
        if shape != .oneTime {
            var sub: [String: Any] = [
                "period": "P1Y", "periodUnit": "year", "periodValue": 1,
                "introOfferEligible": shape == .eligibleTrial,
            ]
            if shape == .eligibleTrial || shape == .offerButIneligible {
                sub["introOffers"] = [[
                    "type": "IntroOffer", "displayPrice": "Free",
                    "periodUnit": "day", "periodValue": 7, "periodCount": 1,
                    "paymentMode": "FreeTrial",
                ]]
            }
            json["subscription"] = sub
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(ServerProductPrice.self, from: data)
    }

    private func map(_ entries: [(String, Shape)]) throws -> [String: ServerProductPrice] {
        var result: [String: ServerProductPrice] = [:]
        for (key, shape) in entries {
            result[key] = try price(key, shape)
        }
        return result
    }

    private let yearlyTrial = "pro_yearly:pri_trial_7d"
    private let monthlyNoTrial = "pro_monthly:pri_main_monthly"
    private let lifetime = "pro_lifetime:pri_one_time"

    // MARK: - The reported defect

    func testNoTrialProductDoesNotMaskAnEligibleCustomer() throws {
        // A web paywall offering a yearly trial next to a monthly plan with no
        // trial. The monthly entry is false for every customer because it has no
        // trial at all, so it is not offer-bearing and must not be counted.
        let priceMap = try map([(yearlyTrial, .eligibleTrial), (monthlyNoTrial, .noTrial)])

        XCTAssertTrue(ExternalWebCheckoutManager.introOfferEligible(
            products: [monthlyNoTrial, yearlyTrial], priceMap: priceMap))
    }

    func testOrderOfOfferedProductsDoesNotMatter() throws {
        let priceMap = try map([(yearlyTrial, .eligibleTrial), (monthlyNoTrial, .noTrial)])

        XCTAssertTrue(ExternalWebCheckoutManager.introOfferEligible(
            products: [yearlyTrial, monthlyNoTrial], priceMap: priceMap))
    }

    func testOneTimeProductDoesNotMaskAnEligibleCustomer() throws {
        let priceMap = try map([(yearlyTrial, .eligibleTrial), (lifetime, .oneTime)])

        XCTAssertTrue(ExternalWebCheckoutManager.introOfferEligible(
            products: [lifetime, yearlyTrial], priceMap: priceMap))
    }

    // MARK: - Cases that must stay false

    func testConsumedTrialIsFalse() throws {
        // Bandit omits introOffers once the customer has used their intro offer,
        // so nothing is offer-bearing and the answer is false.
        let priceMap = try map([(yearlyTrial, .consumedTrial), (monthlyNoTrial, .noTrial)])

        XCTAssertFalse(ExternalWebCheckoutManager.introOfferEligible(
            products: [yearlyTrial, monthlyNoTrial], priceMap: priceMap))
    }

    func testPaywallWithNoTrialsAtAllIsFalse() throws {
        let priceMap = try map([(monthlyNoTrial, .noTrial)])

        XCTAssertFalse(ExternalWebCheckoutManager.introOfferEligible(
            products: [monthlyNoTrial], priceMap: priceMap))
    }

    func testEmptyProductListIsFalse() throws {
        let priceMap = try map([(yearlyTrial, .eligibleTrial)])

        XCTAssertFalse(ExternalWebCheckoutManager.introOfferEligible(
            products: [], priceMap: priceMap))
    }

    func testProductMissingFromPriceMapIsFalse() throws {
        XCTAssertFalse(ExternalWebCheckoutManager.introOfferEligible(
            products: [yearlyTrial], priceMap: [:]))
    }

    func testOnlyOneTimeProductsIsFalse() throws {
        let priceMap = try map([(lifetime, .oneTime)])

        XCTAssertFalse(ExternalWebCheckoutManager.introOfferEligible(
            products: [lifetime], priceMap: priceMap))
    }

    // MARK: - Every offer-bearing product must agree

    func testOfferBearingButIneligibleFailsTheCheck() throws {
        // Not a shape bandit emits today: it sets the flag and the offer array
        // together. Pinned so the contract stays "every offer-bearing product is
        // eligible" rather than degrading to "any product is eligible" if the
        // server ever starts sending offers to ineligible customers.
        let priceMap = try map([
            (yearlyTrial, .eligibleTrial),
            ("pro_yearly:pri_trial_14d", .offerButIneligible),
        ])

        XCTAssertFalse(ExternalWebCheckoutManager.introOfferEligible(
            products: [yearlyTrial, "pro_yearly:pri_trial_14d"], priceMap: priceMap))
    }

    func testUnknownProductAlongsideAnEligibleOneIsStillTrue() throws {
        let priceMap = try map([(yearlyTrial, .eligibleTrial)])

        XCTAssertTrue(ExternalWebCheckoutManager.introOfferEligible(
            products: ["pro_ghost:pri_missing", yearlyTrial], priceMap: priceMap))
    }
}
