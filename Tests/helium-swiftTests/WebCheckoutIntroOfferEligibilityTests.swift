import XCTest
@testable import Helium

/// Covers the price-map derivation used when `/check-entitlement` returns no
/// eligibility value. Fixtures are decoded from the on-launch wire shape rather than
/// hand-constructed, so a rename on the server side surfaces here.
final class WebCheckoutIntroOfferEligibilityTests: XCTestCase {

    private func price(_ productKey: String, introOfferEligible: Bool?) throws -> ServerProductPrice {
        let parts = productKey.split(separator: ":")
        var json: [String: Any] = [
            "id": String(parts[0]),
            "priceId": String(parts[1]),
            "formattedPrice": "$29.99",
            "currency": "USD",
            "productType": "subscription",
        ]
        if let introOfferEligible {
            json["subscription"] = [
                "period": "P1Y",
                "periodUnit": "year",
                "periodValue": 1,
                "introOfferEligible": introOfferEligible,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(ServerProductPrice.self, from: data)
    }

    private func map(_ entries: [(String, Bool?)]) throws -> [String: ServerProductPrice] {
        var result: [String: ServerProductPrice] = [:]
        for (key, eligible) in entries {
            result[key] = try price(key, introOfferEligible: eligible)
        }
        return result
    }

    private let yearlyTrial = "pro_yearly:pri_trial_7d"
    private let monthlyNoTrial = "pro_monthly:pri_main_monthly"

    // MARK: - The reported defect

    func testNoTrialProductDoesNotMaskAnEligibleCustomer() throws {
        // A web paywall offering a yearly trial alongside a monthly plan with no
        // trial. The monthly entry is false for every customer because it has no
        // trial period at all, and must not veto the yearly signal.
        let priceMap = try map([(yearlyTrial, true), (monthlyNoTrial, false)])

        XCTAssertTrue(ExternalWebCheckoutManager.introOfferEligible(
            products: [monthlyNoTrial, yearlyTrial], priceMap: priceMap))
    }

    func testOrderOfOfferedProductsDoesNotMatter() throws {
        let priceMap = try map([(yearlyTrial, true), (monthlyNoTrial, false)])

        XCTAssertTrue(ExternalWebCheckoutManager.introOfferEligible(
            products: [yearlyTrial, monthlyNoTrial], priceMap: priceMap))
    }

    // MARK: - Cases that must stay false

    func testIneligibleCustomerIsFalseEvenWithSeveralTrialProducts() throws {
        // The server applies one customer-level bit to every trial-bearing
        // price, so an ineligible customer is false everywhere.
        let priceMap = try map([(yearlyTrial, false), ("pro_yearly:pri_trial_14d", false)])

        XCTAssertFalse(ExternalWebCheckoutManager.introOfferEligible(
            products: [yearlyTrial, "pro_yearly:pri_trial_14d"], priceMap: priceMap))
    }

    func testPaywallWithNoTrialsAtAllIsFalse() throws {
        let priceMap = try map([(monthlyNoTrial, false)])

        XCTAssertFalse(ExternalWebCheckoutManager.introOfferEligible(
            products: [monthlyNoTrial], priceMap: priceMap))
    }

    func testEmptyProductListIsFalse() throws {
        let priceMap = try map([(yearlyTrial, true)])

        XCTAssertFalse(ExternalWebCheckoutManager.introOfferEligible(
            products: [], priceMap: priceMap))
    }

    func testProductMissingFromPriceMapIsFalse() throws {
        XCTAssertFalse(ExternalWebCheckoutManager.introOfferEligible(
            products: [yearlyTrial], priceMap: [:]))
    }

    func testEntryWithoutASubscriptionBlockIsFalse() throws {
        // One-time products carry no subscription detail.
        let priceMap = try map([(monthlyNoTrial, nil)])

        XCTAssertFalse(ExternalWebCheckoutManager.introOfferEligible(
            products: [monthlyNoTrial], priceMap: priceMap))
    }

    func testUnknownProductAlongsideAnEligibleOneIsStillTrue() throws {
        let priceMap = try map([(yearlyTrial, true)])

        XCTAssertTrue(ExternalWebCheckoutManager.introOfferEligible(
            products: ["pro_ghost:pri_missing", yearlyTrial], priceMap: priceMap))
    }
}
