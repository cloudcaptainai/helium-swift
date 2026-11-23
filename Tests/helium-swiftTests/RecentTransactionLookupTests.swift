import XCTest
@testable import Helium

final class RecentTransactionLookupTests: XCTestCase {
    private let tappedAt = Date(timeIntervalSince1970: 1_000)

    private func transaction(purchasedAt: Date?, productId: String = "monthly") -> HeliumTransactionIdResult {
        HeliumTransactionIdResult(
            productId: productId,
            transactionId: "transaction",
            originalTransactionId: "original",
            purchaseDate: purchasedAt
        )
    }

    func testHistoricalTransactionForTappedPlanIsNotAttached() {
        let historical = transaction(purchasedAt: tappedAt.addingTimeInterval(-1))

        XCTAssertNil(historical.forPurchase(productId: "monthly", purchasedOnOrAfter: tappedAt))
    }

    func testTransactionAtOrAfterTapIsAccepted() {
        for purchaseDate in [tappedAt, tappedAt.addingTimeInterval(1)] {
            let recent = transaction(purchasedAt: purchaseDate)
                .forPurchase(productId: "monthly", purchasedOnOrAfter: tappedAt)

            XCTAssertEqual(recent?.transactionId, "transaction")
            XCTAssertEqual(recent?.originalTransactionId, "original")
        }
    }

    func testRecentTransactionForAnotherProductIsNotAttached() {
        let otherProduct = transaction(purchasedAt: tappedAt, productId: "yearly")

        XCTAssertNil(otherProduct.forPurchase(productId: "monthly", purchasedOnOrAfter: tappedAt))
    }

    func testTransactionWithoutPurchaseDateIsNotAttached() {
        XCTAssertNil(transaction(purchasedAt: nil).forPurchase(productId: "monthly", purchasedOnOrAfter: tappedAt))
    }
}
