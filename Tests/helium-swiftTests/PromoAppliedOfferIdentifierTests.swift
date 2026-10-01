import XCTest
@testable import Helium

final class PromoAppliedOfferIdentifierTests: XCTestCase {

    // A real StoreKit Transaction cannot be constructed in unit tests, so only
    // the nil-transaction path is covered: the requested offer id wins.
    func testNilTransactionReportsRequestedOffer() {
        XCTAssertEqual(
            HeliumPaywallDelegateWrapper.appliedPromoOfferIdentifier(transaction: nil, requested: "offer"),
            "offer"
        )
    }

    func testNilTransactionWithNilRequestReportsNil() {
        XCTAssertNil(
            HeliumPaywallDelegateWrapper.appliedPromoOfferIdentifier(transaction: nil, requested: nil)
        )
    }
}
