import XCTest
@testable import Helium

private final class ScriptedTransactionLookup: StoreTransactionLookup, @unchecked Sendable {
    struct Response {
        let outcome: StoreTransactionLookupOutcome
        var delayMilliseconds: UInt64 = 0
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var _callCount = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    init(_ responses: [Response]) {
        self.responses = responses
    }

    convenience init(_ snapshots: [StoreTransactionSnapshot?]) {
        self.init(snapshots.map { Response(outcome: $0.map { .verified($0) } ?? .noTransaction) })
    }

    func latestTransaction(productId: String) async -> StoreTransactionLookupOutcome {
        let response: Response? = {
            lock.lock()
            defer { lock.unlock() }
            _callCount += 1
            return responses.isEmpty ? nil : responses.removeFirst()
        }()
        guard let response else { return .noTransaction }
        if response.delayMilliseconds > 0 {
            try? await Task.sleep(nanoseconds: response.delayMilliseconds * 1_000_000)
        }
        return response.outcome
    }
}

private final class TransactionReturningMockDelegate: MockHeliumPaywallDelegate, HeliumDelegateReturnsTransaction {
    var latestTransaction: HeliumTransactionIdResult?

    func getLatestCompletedTransactionIdResult() -> HeliumTransactionIdResult? {
        latestTransaction
    }
}

private final class ObservabilityEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [any HeliumObservabilityEvent] = []

    var recheckEvents: [PurchaseStoreRecheckCompleted] {
        lock.lock()
        defer { lock.unlock() }
        return _events.compactMap { $0 as? PurchaseStoreRecheckCompleted }
    }

    func record(_ event: any HeliumObservabilityEvent) {
        lock.lock()
        defer { lock.unlock() }
        _events.append(event)
    }
}

private func snapshot(
    transactionId: String,
    isRevoked: Bool = false,
    isPurchaseReason: Bool = true,
    isOwnedByPurchaser: Bool = true
) -> StoreTransactionSnapshot {
    StoreTransactionSnapshot(
        ids: HeliumTransactionIdResult(productId: "test_yearly", transactionId: transactionId, originalTransactionId: transactionId),
        isRevoked: isRevoked,
        isPurchaseReason: isPurchaseReason,
        isOwnedByPurchaser: isOwnedByPurchaser
    )
}

final class StoreCompletedPurchaseCheckTests: XCTestCase {

    func testNewTransactionCounts() {
        XCTAssertTrue(StoreCompletedPurchaseCheck.isCompletedDuringAttempt(
            snapshot(transactionId: "2"),
            baselineTransactionId: "1"
        ))
    }

    func testFirstTransactionCountsWhenTheStoreHeldNoneBefore() {
        XCTAssertTrue(StoreCompletedPurchaseCheck.isCompletedDuringAttempt(
            snapshot(transactionId: "1"),
            baselineTransactionId: nil
        ))
    }

    func testTransactionAlreadyPresentBeforeAttemptDoesNotCount() {
        XCTAssertFalse(StoreCompletedPurchaseCheck.isCompletedDuringAttempt(
            snapshot(transactionId: "1"),
            baselineTransactionId: "1"
        ))
    }

    func testRenewalDuringAttemptDoesNotCount() {
        XCTAssertFalse(StoreCompletedPurchaseCheck.isCompletedDuringAttempt(
            snapshot(transactionId: "2", isPurchaseReason: false),
            baselineTransactionId: "1"
        ))
    }

    func testFamilySharedTransactionDoesNotCount() {
        XCTAssertFalse(StoreCompletedPurchaseCheck.isCompletedDuringAttempt(
            snapshot(transactionId: "2", isOwnedByPurchaser: false),
            baselineTransactionId: "1"
        ))
    }

    func testRevokedTransactionDoesNotCount() {
        XCTAssertFalse(StoreCompletedPurchaseCheck.isCompletedDuringAttempt(
            snapshot(transactionId: "2", isRevoked: true),
            baselineTransactionId: "1"
        ))
    }

    func testNoTransactionDoesNotCount() {
        XCTAssertFalse(StoreCompletedPurchaseCheck.isCompletedDuringAttempt(
            nil,
            baselineTransactionId: nil
        ))
    }
}

final class StoreCompletedPurchaseRoutingTests: HeliumTestCase {

    private var recorder: ObservabilityEventRecorder!

    override func setUp() {
        super.setUp()
        let recorder = ObservabilityEventRecorder()
        self.recorder = recorder
        HeliumObservabilityManager.shared.unitTestTrackObserver = { recorder.record($0) }
    }

    override func tearDown() {
        HeliumObservabilityManager.shared.unitTestTrackObserver = nil
        super.tearDown()
    }

    private func purchase(productKey: String = "test_yearly") async -> HeliumPaywallTransactionStatus {
        await HeliumPaywallDelegateWrapper.shared.handlePurchase(
            productKey: productKey,
            triggerName: "test_trigger",
            paywallTemplateName: "test_paywall",
            paywallSession: makeTestSession(trigger: "test_trigger")
        )
    }

    private func enableCancelRecheck() {
        HeliumFetchedConfigManager.shared.setFeatureFlagsForTesting(JSON(["storeRecheckAfterCancel": true]))
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
        XCTAssertEqual(recorder.recheckEvents.count, 1)
        XCTAssertEqual(recorder.recheckEvents.first?.recoveredTransactionId, "new_txn")
        XCTAssertEqual(recorder.recheckEvents.first?.delegateResult, .failed)
    }

    func testCancelledPurchaseTheStoreCompletedIsReportedAsPurchasedWhenFlagIsOn() async {
        enableCancelRecheck()
        HeliumPaywallDelegateWrapper.shared.storeTransactionLookup = ScriptedTransactionLookup([
            snapshot(transactionId: "old_txn"),
            snapshot(transactionId: "new_txn"),
        ])
        mockDelegate.purchaseResult = .cancelled

        let status = await purchase()

        guard case .purchased = status else {
            return XCTFail("expected purchased, got \(status)")
        }
        waitForEventDispatch { self.listener.eventsOfType(PurchaseSucceededEvent.self).count == 1 }
        XCTAssertEqual(listener.eventsOfType(PurchaseSucceededEvent.self).first?.storeKitTransactionId, "new_txn")
        XCTAssertTrue(listener.eventsOfType(PurchaseCancelledEvent.self).isEmpty)
    }

    func testCancelledPurchaseIsNotRecheckedWhenFlagIsOff() async {
        let lookup = ScriptedTransactionLookup([
            snapshot(transactionId: "old_txn"),
            snapshot(transactionId: "new_txn"),
        ])
        HeliumPaywallDelegateWrapper.shared.storeTransactionLookup = lookup
        mockDelegate.purchaseResult = .cancelled

        let status = await purchase()

        guard case .cancelled = status else {
            return XCTFail("expected cancelled, got \(status)")
        }
        XCTAssertEqual(lookup.callCount, 1, "only the pre-purchase baseline should query StoreKit")
        XCTAssertEqual(recorder.recheckEvents.first?.skipReason, .cancelRecheckDisabled)
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
        XCTAssertNil(recorder.recheckEvents.first?.recoveredTransactionId)
    }

    func testFailedPurchaseIsNotRecheckedWhenTheBaselineDidNotFinish() async {
        let lookup = ScriptedTransactionLookup([
            .init(outcome: .noTransaction, delayMilliseconds: 1_500),
            .init(outcome: .verified(snapshot(transactionId: "new_txn"))),
        ])
        HeliumPaywallDelegateWrapper.shared.storeTransactionLookup = lookup
        mockDelegate.purchaseResult = .failed(NSError(domain: "network", code: -1001))

        let status = await purchase()

        guard case .failed = status else {
            return XCTFail("expected failed, got \(status)")
        }
        XCTAssertEqual(lookup.callCount, 1)
        XCTAssertEqual(recorder.recheckEvents.first?.baselineState, .timedOut)
        XCTAssertEqual(recorder.recheckEvents.first?.skipReason, .baselineTimedOut)
        XCTAssertNil(recorder.recheckEvents.first?.recheckDurationMs)
    }

    func testFailedPurchaseStaysFailedWhenTheRecheckTimesOut() async {
        HeliumPaywallDelegateWrapper.shared.storeTransactionLookup = ScriptedTransactionLookup([
            .init(outcome: .noTransaction),
            .init(outcome: .verified(snapshot(transactionId: "new_txn")), delayMilliseconds: 10_000),
        ])
        mockDelegate.purchaseResult = .failed(NSError(domain: "network", code: -1001))

        let startedAt = Date()
        let status = await purchase()

        guard case .failed = status else {
            return XCTFail("expected failed, got \(status)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5, "the recheck should stop waiting on a slow StoreKit lookup")
        XCTAssertEqual(recorder.recheckEvents.first?.recheckTimedOut, true)
    }

    func testWebCheckoutKeyIsNotRechecked() async {
        let lookup = ScriptedTransactionLookup([nil, snapshot(transactionId: "new_txn")])
        HeliumPaywallDelegateWrapper.shared.storeTransactionLookup = lookup

        let status = await purchase(productKey: "prod_abc:price_def")

        guard case .failed = status else {
            return XCTFail("expected failed, got \(status)")
        }
        XCTAssertEqual(lookup.callCount, 0)
        XCTAssertEqual(recorder.recheckEvents.first?.skipReason, .notAppStore)
    }

    func testFailedPurchaseIsNotRecheckedWhenTheBaselineWasUnverified() async {
        let lookup = ScriptedTransactionLookup([
            .init(outcome: .unverified),
            .init(outcome: .verified(snapshot(transactionId: "new_txn"))),
        ])
        HeliumPaywallDelegateWrapper.shared.storeTransactionLookup = lookup
        mockDelegate.purchaseResult = .failed(NSError(domain: "network", code: -1001))

        let status = await purchase()

        guard case .failed = status else {
            return XCTFail("expected failed, got \(status)")
        }
        XCTAssertEqual(lookup.callCount, 1)
        XCTAssertEqual(recorder.recheckEvents.first?.baselineState, .unverified)
        XCTAssertEqual(recorder.recheckEvents.first?.skipReason, .baselineUnverified)
    }

    func testSimulatedPurchaseIsNotRecheckedAndTakesNoBaseline() async throws {
        Helium.testing.purchaseHandler = { _ in .failed(NSError(domain: "simulated", code: 1)) }
        defer { Helium.testing.reset() }
        try XCTSkipUnless(Helium.testing.isPurchaseSimulationActive, "purchase simulation is ignored in a production environment")
        let lookup = ScriptedTransactionLookup([nil, snapshot(transactionId: "new_txn")])
        HeliumPaywallDelegateWrapper.shared.storeTransactionLookup = lookup

        let status = await purchase()

        guard case .failed = status else {
            return XCTFail("expected failed, got \(status)")
        }
        XCTAssertEqual(lookup.callCount, 0)
        XCTAssertEqual(recorder.recheckEvents.first?.skipReason, .simulatedPurchase)
        XCTAssertNil(recorder.recheckEvents.first?.baselineState)
    }

    func testPurchasedResultUsesTheDelegatesTransaction() async {
        let delegate = TransactionReturningMockDelegate()
        delegate.purchaseResult = .purchased
        delegate.latestTransaction = HeliumTransactionIdResult(productId: "test_yearly", transactionId: "delegate_txn", originalTransactionId: "delegate_txn")
        Helium.config.purchaseDelegate = delegate
        HeliumPaywallDelegateWrapper.shared.storeTransactionLookup = ScriptedTransactionLookup([
            nil,
            snapshot(transactionId: "store_txn"),
        ])

        let status = await purchase()

        guard case .purchased = status else {
            return XCTFail("expected purchased, got \(status)")
        }
        waitForEventDispatch { self.listener.eventsOfType(PurchaseSucceededEvent.self).count == 1 }
        XCTAssertEqual(listener.eventsOfType(PurchaseSucceededEvent.self).first?.storeKitTransactionId, "delegate_txn")
    }
}
