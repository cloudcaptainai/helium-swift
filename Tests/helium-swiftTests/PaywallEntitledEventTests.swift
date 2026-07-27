import XCTest
@testable import Helium

final class PaywallEntitledEventTests: HeliumTestCase {

    // MARK: - Mark/consume semantics

    func testConsumeReturnsMarkedEventOnce() {
        let purchased = PurchaseSucceededEvent(
            productId: "com.test.product", triggerName: "t", paywallName: "p",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil
        )
        let sessionId = UUID().uuidString
        HeliumPaywallPresenter.shared.markSessionAsEntitled(sessionId: sessionId, event: .purchased(purchased))

        let consumed = HeliumPaywallPresenter.shared.consumeEntitledEvent(forSessionId: sessionId)
        guard case .purchased(let event)? = consumed else {
            return XCTFail("Expected .purchased, got \(String(describing: consumed))")
        }
        XCTAssertEqual(event.productId, "com.test.product")

        XCTAssertNil(HeliumPaywallPresenter.shared.consumeEntitledEvent(forSessionId: sessionId))
    }

    func testConsumeReturnsNilForUnmarkedSession() {
        XCTAssertNil(HeliumPaywallPresenter.shared.consumeEntitledEvent(forSessionId: UUID().uuidString))
    }

    func testLastEntitlingEventWins() {
        let purchased = PurchaseSucceededEvent(
            productId: "com.test.product", triggerName: "t", paywallName: "p",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil
        )
        let restored = PurchaseRestoredEvent(
            productId: "com.test.restored", triggerName: "t", paywallName: "p",
            restoreOrigin: .restorePurchases, paymentProcessor: .appStore
        )
        let sessionId = UUID().uuidString
        HeliumPaywallPresenter.shared.markSessionAsEntitled(sessionId: sessionId, event: .purchased(purchased))
        HeliumPaywallPresenter.shared.markSessionAsEntitled(sessionId: sessionId, event: .restored(restored))

        let consumed = HeliumPaywallPresenter.shared.consumeEntitledEvent(forSessionId: sessionId)
        guard case .restored(let event)? = consumed else {
            return XCTFail("Expected .restored, got \(String(describing: consumed))")
        }
        XCTAssertEqual(event.productId, "com.test.restored")
    }

    // MARK: - fireEvent marks the session with the matching event

    func testFireEventMarksSessionForPurchaseSucceeded() {
        let session = makeTestSession(trigger: "t")
        let event = PurchaseSucceededEvent(
            productId: "com.test.product", triggerName: "t", paywallName: "p",
            storeKitTransactionId: "txn_1", storeKitOriginalTransactionId: nil
        )
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: session)
        waitForEventDispatch { self.listener.eventsOfType(PurchaseSucceededEvent.self).count == 1 }

        let consumed = HeliumPaywallPresenter.shared.consumeEntitledEvent(forSessionId: session.sessionId)
        guard case .purchased(let marked)? = consumed else {
            return XCTFail("Expected .purchased, got \(String(describing: consumed))")
        }
        XCTAssertEqual(marked.productId, "com.test.product")
        XCTAssertEqual(consumed?.productId, "com.test.product")
    }

    func testFireEventMarksSessionForPurchaseRestored() {
        let session = makeTestSession(trigger: "t")
        let event = PurchaseRestoredEvent(
            productId: "com.test.product", triggerName: "t", paywallName: "p",
            restoreOrigin: .duringPurchase, paymentProcessor: .appStore
        )
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: session)
        waitForEventDispatch { self.listener.eventsOfType(PurchaseRestoredEvent.self).count == 1 }

        let consumed = HeliumPaywallPresenter.shared.consumeEntitledEvent(forSessionId: session.sessionId)
        guard case .restored(let marked)? = consumed else {
            return XCTFail("Expected .restored, got \(String(describing: consumed))")
        }
        XCTAssertEqual(marked.restoreOrigin, .duringPurchase)
    }

    func testFireEventMarksSessionForPurchaseAlreadyEntitled() {
        let session = makeTestSession(trigger: "t")
        let event = PurchaseAlreadyEntitledEvent(
            productId: "com.test.product", triggerName: "t", paywallName: "p",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil
        )
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: session)
        waitForEventDispatch { self.listener.eventsOfType(PurchaseAlreadyEntitledEvent.self).count == 1 }

        let consumed = HeliumPaywallPresenter.shared.consumeEntitledEvent(forSessionId: session.sessionId)
        guard case .alreadyEntitled? = consumed else {
            return XCTFail("Expected .alreadyEntitled, got \(String(describing: consumed))")
        }
    }

    func testFireEventDoesNotMarkSessionForNonEntitlingEvent() {
        let session = makeTestSession(trigger: "t")
        let event = PurchaseFailedEvent(productId: "com.test.product", triggerName: "t", paywallName: "p", paymentProcessor: .appStore)
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: session)
        waitForEventDispatch { self.listener.eventsOfType(PurchaseFailedEvent.self).count == 1 }

        XCTAssertNil(HeliumPaywallPresenter.shared.consumeEntitledEvent(forSessionId: session.sessionId))
    }

    // MARK: - Already-entitled skip path

    func testAlreadyEntitledSkipCallsOnEntitledWithSkippedEvent() {
        var received: PaywallEntitledEvent?
        var notShownReason: PaywallNotShownReason?
        let context = PaywallPresentationContext(
            config: PaywallPresentationConfig(dontShowIfAlreadyEntitled: true),
            eventHandlers: nil,
            onEntitled: { received = $0 },
            onPaywallNotShown: { notShownReason = $0 }
        )

        HeliumPaywallPresenter.shared.handleAlreadyEntitledSkip(trigger: "entitled_trigger", context: context)
        waitForEventDispatch { received != nil }

        guard case .skipped(let skipEvent)? = received else {
            return XCTFail("Expected .skipped, got \(String(describing: received))")
        }
        XCTAssertEqual(skipEvent.triggerName, "entitled_trigger")
        XCTAssertEqual(skipEvent.skipReason, .alreadyEntitled)
        XCTAssertNil(received?.productId)
        XCTAssertNil(notShownReason)

        // The same skip event is also fired through the event system
        waitForEventDispatch { self.listener.eventsOfType(PaywallSkippedEvent.self).count == 1 }
        XCTAssertEqual(listener.lastEvent(ofType: PaywallSkippedEvent.self)?.skipReason, .alreadyEntitled)
    }

    func testAlreadyEntitledSkipWithoutOnEntitledCallsOnPaywallNotShown() {
        var notShownReason: PaywallNotShownReason?
        let context = PaywallPresentationContext(
            config: PaywallPresentationConfig(dontShowIfAlreadyEntitled: true),
            eventHandlers: nil,
            onEntitled: nil,
            onPaywallNotShown: { notShownReason = $0 }
        )

        HeliumPaywallPresenter.shared.handleAlreadyEntitledSkip(trigger: "entitled_trigger", context: context)
        waitForEventDispatch { notShownReason != nil }

        XCTAssertEqual(notShownReason, .alreadyEntitled)
    }

    // MARK: - Accessors

    func testEventAccessorReturnsUnderlyingEvent() {
        let skipEvent = PaywallSkippedEvent(triggerName: "t", skipReason: .alreadyEntitled)
        let entitled = PaywallEntitledEvent.skipped(skipEvent)
        XCTAssertTrue(entitled.event is PaywallSkippedEvent)
        XCTAssertNil(entitled.productId)

        let purchased = PurchaseSucceededEvent(
            productId: "com.test.product", triggerName: "t", paywallName: "p",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil
        )
        XCTAssertEqual(PaywallEntitledEvent.purchased(purchased).productId, "com.test.product")
        XCTAssertTrue(PaywallEntitledEvent.purchased(purchased).event is PurchaseSucceededEvent)
    }

    // MARK: - Overload resolution (compile-time check, never executed)

    private let overloadResolutionCheck: () -> Void = {
        // Zero-arg closure resolves to the deprecated overload; one-arg closure to the new one.
        let zeroArg = {
            Helium.shared.presentPaywall(trigger: "t", onEntitled: {}, onPaywallNotShown: { _ in })
        }
        let oneArg = {
            Helium.shared.presentPaywall(trigger: "t", onEntitled: { (_: PaywallEntitledEvent) in }, onPaywallNotShown: { _ in })
        }
        let omitted = {
            Helium.shared.presentPaywall(trigger: "t", onPaywallNotShown: { _ in })
        }
        _ = (zeroArg, oneArg, omitted)
    }
}
