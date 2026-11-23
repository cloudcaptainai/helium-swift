import StoreKit
import XCTest
@testable import Helium

private final class SelectionPayment: SKPayment {
    private let id: String

    init(productId: String) {
        id = productId
        super.init()
    }

    override var productIdentifier: String { id }
}

private final class SelectionTransaction: SKPaymentTransaction {
    private let selectedPayment: SKPayment
    private let date: Date?
    private let state: SKPaymentTransactionState

    init(productId: String = "monthly", date: Date?, state: SKPaymentTransactionState = .purchased) {
        selectedPayment = SelectionPayment(productId: productId)
        self.date = date
        self.state = state
        super.init()
    }

    override var payment: SKPayment { selectedPayment }
    override var transactionDate: Date? { date }
    override var transactionState: SKPaymentTransactionState { state }
}

final class StoreKit1TransactionSelectionTests: XCTestCase {
    private let tap = Date(timeIntervalSince1970: 1_000)

    func testRepeatPurchaseSelectsNewestEligibleTransactionRegardlessOfOrder() {
        let old = SelectionTransaction(date: tap.addingTimeInterval(-10))
        let recent = SelectionTransaction(date: tap)
        let newest = SelectionTransaction(date: tap.addingTimeInterval(1))
        let otherProduct = SelectionTransaction(productId: "yearly", date: tap.addingTimeInterval(2))
        let pending = SelectionTransaction(date: tap.addingTimeInterval(3), state: .deferred)
        let undated = SelectionTransaction(date: nil)

        for transactions in [
            [old, recent, newest, otherProduct, pending, undated],
            [undated, pending, otherProduct, newest, recent, old],
        ] {
            XCTAssertTrue(StoreKit1TransactionSelection.latest(
                in: transactions, productId: "monthly", purchasedOnOrAfter: tap
            ) === newest)
        }
    }

    func testNoEligibleTransactionReturnsNil() {
        let old = SelectionTransaction(date: tap.addingTimeInterval(-1))
        let undated = SelectionTransaction(date: nil)

        for transactions in [[], [old, undated]] {
            XCTAssertNil(StoreKit1TransactionSelection.latest(
                in: transactions, productId: "monthly", purchasedOnOrAfter: tap
            ))
        }
    }
}
