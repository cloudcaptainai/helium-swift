import XCTest
@testable import Helium

private final class ScriptedTransactionLookup: StoreTransactionLookup {
    private let lock = NSLock()
    private var responses: [StoreTransactionSnapshot?]

    init(_ responses: [StoreTransactionSnapshot?]) {
        self.responses = responses
    }

    func latestTransaction(productId: String) async -> StoreTransactionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return responses.isEmpty ? nil : responses.removeFirst()
    }
}

private func snapshot(
    transactionId: String,
    purchaseDate: Date = Date(),
    isRevoked: Bool = false
) -> StoreTransactionSnapshot {
    StoreTransactionSnapshot(
        ids: HeliumTransactionIdResult(productId: "test_yearly", transactionId: transactionId, originalTransactionId: transactionId),
        purchaseDate: purchaseDate,
        isRevoked: isRevoked
    )
}

final class StoreCompletedPurchaseCheckTests: XCTestCase {

    private let attemptStartedAt = Date()

    func testNewTransactionDuringAttemptCounts() {
        XCTAssertTrue(StoreCompletedPurchaseCheck.isCompletedDuringAttempt(
            snapshot(transactionId: "2", purchaseDate: attemptStartedAt.addingTimeInterval(5)),
            baselineTransactionId: "1",
            attemptStartedAt: attemptStartedAt
        ))
    }

    func testTransactionAlreadyPresentBeforeAttemptDoesNotCount() {
        XCTAssertFalse(StoreCompletedPurchaseCheck.isCompletedDuringAttempt(
            snapshot(transactionId: "1", purchaseDate: attemptStartedAt.addingTimeInterval(5)),
            baselineTransactionId: "1",
            attemptStartedAt: attemptStartedAt
        ))
    }

    func testOldTransactionDoesNotCountWhenBaselineIsUnknown() {
        XCTAssertFalse(StoreCompletedPurchaseCheck.isCompletedDuringAttempt(
            snapshot(transactionId: "1", purchaseDate: attemptStartedAt.addingTimeInterval(-24 * 60 * 60)),
            baselineTransactionId: nil,
            attemptStartedAt: attemptStartedAt
        ))
    }

    func testDeviceClockAheadOfStoreStillCounts() {
        XCTAssertTrue(StoreCompletedPurchaseCheck.isCompletedDuringAttempt(
            snapshot(transactionId: "2", purchaseDate: attemptStartedAt.addingTimeInterval(-60)),
            baselineTransactionId: nil,
            attemptStartedAt: attemptStartedAt
        ))
    }

    func testRevokedTransactionDoesNotCount() {
        XCTAssertFalse(StoreCompletedPurchaseCheck.isCompletedDuringAttempt(
            snapshot(transactionId: "2", isRevoked: true),
            baselineTransactionId: "1",
            attemptStartedAt: attemptStartedAt
        ))
    }

    func testNoTransactionDoesNotCount() {
        XCTAssertFalse(StoreCompletedPurchaseCheck.isCompletedDuringAttempt(
            nil,
            baselineTransactionId: nil,
            attemptStartedAt: attemptStartedAt
        ))
    }
}

final class StoreCompletedPurchaseRoutingTests: HeliumTestCase {

    private func purchase() async -> HeliumPaywallTransactionStatus {
        await HeliumPaywallDelegateWrapper.shared.handlePurchase(
            productKey: "test_yearly",
            triggerName: "test_trigger",
            paywallTemplateName: "test_paywall",
            paywallSession: makeTestSession(trigger: "test_trigger")
        )
    }

    func testFailedPurchaseTheStoreCompletedIsReportedAsPurchased() async {
        HeliumPaywallDelegateWrapper.shared.storeTransactionLookup = ScriptedTransactionLookup([
            nil,
            snapshot(transactionId: "new_txn"),
        ])
        mockDelegate.purchaseResult = .failed(NSError(domain: "network", code: -1001))

        let status = await purchase()

        guard case .purchased = status else {
            return XCTFail("expected purchased, got \(status)")
        }
        waitForEventDispatch { self.listener.eventsOfType(PurchaseSucceededEvent.self).count == 1 }
        XCTAssertEqual(listener.eventsOfType(PurchaseSucceededEvent.self).first?.storeKitTransactionId, "new_txn")
        XCTAssertTrue(listener.eventsOfType(PurchaseFailedEvent.self).isEmpty)
    }

    func testCancelledPurchaseTheStoreCompletedIsReportedAsPurchased() async {
        HeliumPaywallDelegateWrapper.shared.storeTransactionLookup = ScriptedTransactionLookup([
            snapshot(transactionId: "old_txn", purchaseDate: Date().addingTimeInterval(-30 * 24 * 60 * 60)),
            snapshot(transactionId: "new_txn"),
        ])
        mockDelegate.purchaseResult = .cancelled

        let status = await purchase()

        guard case .purchased = status else {
            return XCTFail("expected purchased, got \(status)")
        }
        waitForEventDispatch { self.listener.eventsOfType(PurchaseSucceededEvent.self).count == 1 }
        XCTAssertTrue(listener.eventsOfType(PurchaseCancelledEvent.self).isEmpty)
    }

    func testFailedPurchaseStaysFailedWhenTheStoreHasNoNewTransaction() async {
        let existing = snapshot(transactionId: "old_txn")
        HeliumPaywallDelegateWrapper.shared.storeTransactionLookup = ScriptedTransactionLookup([existing, existing])
        mockDelegate.purchaseResult = .failed(NSError(domain: "network", code: -1001))

        let status = await purchase()

        guard case .failed = status else {
            return XCTFail("expected failed, got \(status)")
        }
        waitForEventDispatch { self.listener.eventsOfType(PurchaseFailedEvent.self).count == 1 }
        XCTAssertTrue(listener.eventsOfType(PurchaseSucceededEvent.self).isEmpty)
    }
}
