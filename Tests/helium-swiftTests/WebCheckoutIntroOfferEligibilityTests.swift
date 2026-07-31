import XCTest
@testable import Helium

/// Covers the price-map derivation used when `/check-entitlement` returns no
/// eligibility value. Fixtures are decoded from JSON rather than hand-built, so
/// a field rename surfaces here.
final class WebCheckoutIntroOfferEligibilityTests: XCTestCase {

    /// Price fixtures, named for what they represent and defined by the fields
    /// they carry.
    private enum Shape {
        /// `introOfferEligible: true`, `introOffers` non-empty.
        case eligibleTrial
        /// `introOfferEligible: false`, `introOffers` omitted — a trial the
        /// customer has already consumed.
        case consumedTrial
        /// `introOfferEligible: false`, `introOffers` omitted — a price with no
        /// trial at all. Identical on the wire to `consumedTrial`, which is why
        /// offer-bearing is keyed on `introOffers`.
        case noTrial
        /// No `subscription` block.
        case oneTime
        /// `introOfferEligible: false`, `introOffers` non-empty. Pins that an
        /// offer-bearing price reporting ineligible still fails the check.
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

        XCTAssertTrue(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [monthlyNoTrial, yearlyTrial], priceMap: priceMap))
    }

    func testOrderOfOfferedProductsDoesNotMatter() throws {
        let priceMap = try map([(yearlyTrial, .eligibleTrial), (monthlyNoTrial, .noTrial)])

        XCTAssertTrue(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [yearlyTrial, monthlyNoTrial], priceMap: priceMap))
    }

    func testOneTimeProductDoesNotMaskAnEligibleCustomer() throws {
        let priceMap = try map([(yearlyTrial, .eligibleTrial), (lifetime, .oneTime)])

        XCTAssertTrue(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [lifetime, yearlyTrial], priceMap: priceMap))
    }

    // MARK: - Cases that must stay false

    func testConsumedTrialIsFalse() throws {
        // A consumed trial arrives with no introOffers, so no price on the
        // paywall is offer-bearing.
        let priceMap = try map([(yearlyTrial, .consumedTrial), (monthlyNoTrial, .noTrial)])

        XCTAssertFalse(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [yearlyTrial, monthlyNoTrial], priceMap: priceMap))
    }

    func testPaywallWithNoTrialsAtAllIsFalse() throws {
        let priceMap = try map([(monthlyNoTrial, .noTrial)])

        XCTAssertFalse(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [monthlyNoTrial], priceMap: priceMap))
    }

    func testEmptyProductListIsFalse() throws {
        let priceMap = try map([(yearlyTrial, .eligibleTrial)])

        XCTAssertFalse(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [], priceMap: priceMap))
    }

    func testProductMissingFromPriceMapIsFalse() throws {
        XCTAssertFalse(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [yearlyTrial], priceMap: [:]))
    }

    func testOnlyOneTimeProductsIsFalse() throws {
        let priceMap = try map([(lifetime, .oneTime)])

        XCTAssertFalse(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [lifetime], priceMap: priceMap))
    }

    // MARK: - Every offer-bearing product must agree

    func testOfferBearingButIneligibleFailsTheCheck() throws {
        // Pins the contract as "every offer-bearing product is eligible" rather
        // than "any product is eligible", should a price ever arrive carrying an
        // offer the customer is not eligible for.
        let priceMap = try map([
            (yearlyTrial, .eligibleTrial),
            ("pro_yearly:pri_trial_14d", .offerButIneligible),
        ])

        XCTAssertFalse(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: [yearlyTrial, "pro_yearly:pri_trial_14d"], priceMap: priceMap))
    }

    func testUnknownProductAlongsideAnEligibleOneIsStillTrue() throws {
        let priceMap = try map([(yearlyTrial, .eligibleTrial)])

        XCTAssertTrue(ExternalWebCheckoutManager.blanketIntroOfferEligibility(
            products: ["pro_ghost:pri_missing", yearlyTrial], priceMap: priceMap))
    }
}
