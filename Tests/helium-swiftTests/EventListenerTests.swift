import XCTest
@testable import Helium

final class EventListenerTests: HeliumTestCase {

    func testAddAndRemoveListener() {
        let extra = CapturingEventListener()
        Helium.shared.addHeliumEventListener(extra)
        waitForListenerRegistration(of: extra, registered: true)

        let event = PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented)
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: nil)
        waitForEventDispatch { extra.eventsOfType(PaywallOpenEvent.self).count == 1 }
        XCTAssertEqual(extra.eventsOfType(PaywallOpenEvent.self).count, 1)

        // Remove and fire again
        Helium.shared.removeHeliumEventListener(extra)
        waitForListenerRegistration(of: extra, registered: false)

        let event2 = PaywallCloseEvent(triggerName: "t", paywallName: "p")
        HeliumPaywallDelegateWrapper.shared.fireEvent(event2, paywallSession: nil)
        waitForEventDispatch { self.listener.eventsOfType(PaywallCloseEvent.self).count == 1 }
        XCTAssertEqual(extra.eventsOfType(PaywallCloseEvent.self).count, 0, "Removed listener should not receive events")
    }

    func testRemoveAllListeners() {
        let extra1 = CapturingEventListener()
        let extra2 = CapturingEventListener()
        Helium.shared.addHeliumEventListener(extra1)
        Helium.shared.addHeliumEventListener(extra2)
        waitForListenerRegistration(of: extra2, registered: true)

        Helium.shared.removeAllHeliumEventListeners()
        waitForListenerRegistration(of: listener, registered: false)

        let event = PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented)
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: nil)
        // No listener to receive events — wait for delegate dispatch instead
        waitForEventDispatch { self.mockDelegate.receivedEvents.count >= 1 }

        XCTAssertEqual(listener.capturedEvents.count, 0, "self.listener should be removed")
        XCTAssertEqual(extra1.capturedEvents.count, 0, "extra1 should be removed")
        XCTAssertEqual(extra2.capturedEvents.count, 0, "extra2 should be removed")
    }

    func testDuplicateListenerNotAdded() {
        let extra = CapturingEventListener()
        Helium.shared.addHeliumEventListener(extra)
        waitForListenerRegistration(of: extra, registered: true)
        Helium.shared.addHeliumEventListener(extra) // duplicate — still registered
        waitForListenerRegistration(of: extra, registered: true)

        let event = PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented)
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: nil)
        waitForEventDispatch { extra.eventsOfType(PaywallOpenEvent.self).count == 1 }

        XCTAssertEqual(extra.eventsOfType(PaywallOpenEvent.self).count, 1,
                       "Duplicate listener should only receive event once")
    }

    func testPaywallEventHandlersOnAnyEventFiresForPaywallContextEvents() {
        var anyEvents: [PaywallContextEvent] = []
        let handlers = PaywallEventHandlers()
            .onAnyEvent { e in anyEvents.append(e) }

        // PaywallContextEvent - should fire
        handlers.handleEvent(PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented))
        XCTAssertEqual(anyEvents.count, 1)

        // Another PaywallContextEvent
        handlers.handleEvent(PurchasePressedEvent(productId: "prod", triggerName: "t", paywallName: "p"))
        XCTAssertEqual(anyEvents.count, 2)

        // PaywallSkippedEvent is NOT a PaywallContextEvent
        handlers.handleEvent(PaywallSkippedEvent(triggerName: "t"))
        XCTAssertEqual(anyEvents.count, 2, "Should not fire for non-PaywallContextEvent")
    }

}
