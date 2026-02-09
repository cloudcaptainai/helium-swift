import XCTest
@testable import Helium

final class EventSystemTests: HeliumTestCase {

    func testFireEventReachesAllThreeTargets() {
        let captor = PaywallEventHandlersCaptor()
        let session = makeTestSession(trigger: "test_trigger", eventHandlers: captor.handlers)
        let event = PaywallDismissedEvent(triggerName: "test_trigger", paywallName: "test_paywall")

        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: session)
        waitForEventDispatch()

        // 1. Session event handlers (captor)
        XCTAssertEqual(captor.dismissedEvents.count, 1)
        XCTAssertEqual(captor.anyEvents.count, 1)

        // 2. Delegate
        let delegateEvents = mockDelegate.receivedEvents.compactMap { $0 as? PaywallDismissedEvent }
        XCTAssertEqual(delegateEvents.count, 1)

        // 3. Global listener
        let listenerEvents = listener.eventsOfType(PaywallDismissedEvent.self)
        XCTAssertEqual(listenerEvents.count, 1)
    }

    func testFireEventWithNilSessionSkipsSessionHandlers() {
        let event = PaywallDismissedEvent(triggerName: "test", paywallName: "wall")

        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: nil)
        waitForEventDispatch()

        // Delegate should still receive it
        let delegateEvents = mockDelegate.receivedEvents.compactMap { $0 as? PaywallDismissedEvent }
        XCTAssertEqual(delegateEvents.count, 1)

        // Listener should still receive it
        let listenerEvents = listener.eventsOfType(PaywallDismissedEvent.self)
        XCTAssertEqual(listenerEvents.count, 1)
    }

    func testMultipleListenersReceiveEvents() {
        let listener2 = CapturingEventListener()
        let listener3 = CapturingEventListener()
        Helium.shared.addHeliumEventListener(listener2)
        Helium.shared.addHeliumEventListener(listener3)

        let event = PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented)
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: nil)
        waitForEventDispatch()

        // All 3 listeners (self.listener + listener2 + listener3) should receive
        XCTAssertEqual(listener.eventsOfType(PaywallOpenEvent.self).count, 1)
        XCTAssertEqual(listener2.eventsOfType(PaywallOpenEvent.self).count, 1)
        XCTAssertEqual(listener3.eventsOfType(PaywallOpenEvent.self).count, 1)
    }

    func testWeakListenerGetsCleanedUp() {
        var weakListener: CapturingEventListener? = CapturingEventListener()
        Helium.shared.addHeliumEventListener(weakListener!)

        // Nil it out
        weakListener = nil

        // Fire event - should not crash
        let event = PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented)
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: nil)
        waitForEventDispatch()

        // Original listener (self.listener) should still work
        XCTAssertEqual(listener.eventsOfType(PaywallOpenEvent.self).count, 1)
    }

    func testEventNameMatchesExpected() {
        let events: [(HeliumEvent, String)] = [
            (PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented), "paywallOpen"),
            (PaywallCloseEvent(triggerName: "t", paywallName: "p"), "paywallClose"),
            (PaywallDismissedEvent(triggerName: "t", paywallName: "p"), "paywallDismissed"),
            (PaywallSkippedEvent(triggerName: "t"), "paywallSkipped"),
            (PurchaseSucceededEvent(productId: "p", triggerName: "t", paywallName: "w", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil), "purchaseSucceeded"),
            (InitializeCalledEvent(), "initializeCalled"),
        ]

        for (event, expectedName) in events {
            XCTAssertEqual(event.eventName, expectedName, "Event \(type(of: event)) has wrong eventName")
        }
    }
}
