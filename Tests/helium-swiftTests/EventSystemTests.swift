import XCTest
@testable import Helium

final class EventSystemTests: HeliumTestCase {

    func testFireEventReachesAllThreeTargets() {
        let captor = PaywallEventHandlersCaptor()
        let session = makeTestSession(trigger: "test_trigger", eventHandlers: captor.handlers)
        let event = PaywallDismissedEvent(triggerName: "test_trigger", paywallName: "test_paywall")

        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: session)
        waitForEventDispatch { self.listener.eventsOfType(PaywallDismissedEvent.self).count == 1 }

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

    func testMultipleListenersReceiveEvents() {
        let listener2 = CapturingEventListener()
        let listener3 = CapturingEventListener()
        Helium.shared.addHeliumEventListener(listener2)
        Helium.shared.addHeliumEventListener(listener3)
        waitForListenerRegistration(of: listener3, registered: true)

        let event = PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented)
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: nil)
        waitForEventDispatch { listener3.eventsOfType(PaywallOpenEvent.self).count == 1 }

        // All 3 listeners (self.listener + listener2 + listener3) should receive
        XCTAssertEqual(listener.eventsOfType(PaywallOpenEvent.self).count, 1)
        XCTAssertEqual(listener2.eventsOfType(PaywallOpenEvent.self).count, 1)
        XCTAssertEqual(listener3.eventsOfType(PaywallOpenEvent.self).count, 1)
    }

    func testWeakListenerDeallocatesAndStopsReceivingEvents() {
        var strongRef: CapturingEventListener? = CapturingEventListener()
        weak var weakRef = strongRef
        Helium.shared.addHeliumEventListener(strongRef!)
        waitForListenerRegistration(of: strongRef!, registered: true)

        // Drop the only strong reference — weak storage in HeliumEventListeners should let it deallocate
        strongRef = nil
        XCTAssertNil(weakRef, "Listener should be deallocated after dropping the strong reference")

        // Fire event — deallocated listener should not receive it and should not crash
        let event = PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented)
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: nil)
        waitForEventDispatch { self.listener.eventsOfType(PaywallOpenEvent.self).count == 1 }

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
