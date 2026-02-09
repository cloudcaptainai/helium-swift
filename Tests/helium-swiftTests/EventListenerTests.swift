import XCTest
@testable import Helium

final class EventListenerTests: HeliumTestCase {

    func testAddAndRemoveListener() {
        let extra = CapturingEventListener()
        Helium.shared.addHeliumEventListener(extra)
        waitForListenerRegistration()

        let event = PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented)
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: nil)
        waitForEventDispatch()
        XCTAssertEqual(extra.eventsOfType(PaywallOpenEvent.self).count, 1)

        // Remove and fire again
        Helium.shared.removeHeliumEventListener(extra)
        waitForListenerRegistration()

        let event2 = PaywallCloseEvent(triggerName: "t", paywallName: "p")
        HeliumPaywallDelegateWrapper.shared.fireEvent(event2, paywallSession: nil)
        waitForEventDispatch()
        XCTAssertEqual(extra.eventsOfType(PaywallCloseEvent.self).count, 0, "Removed listener should not receive events")
    }

    func testRemoveAllListeners() {
        let extra1 = CapturingEventListener()
        let extra2 = CapturingEventListener()
        Helium.shared.addHeliumEventListener(extra1)
        Helium.shared.addHeliumEventListener(extra2)
        waitForListenerRegistration()

        Helium.shared.removeAllHeliumEventListeners()
        waitForListenerRegistration()

        let event = PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented)
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: nil)
        waitForEventDispatch()

        XCTAssertEqual(listener.capturedEvents.count, 0, "self.listener should be removed")
        XCTAssertEqual(extra1.capturedEvents.count, 0, "extra1 should be removed")
        XCTAssertEqual(extra2.capturedEvents.count, 0, "extra2 should be removed")
    }

    func testDuplicateListenerNotAdded() {
        let extra = CapturingEventListener()
        Helium.shared.addHeliumEventListener(extra)
        waitForListenerRegistration()
        Helium.shared.addHeliumEventListener(extra) // duplicate
        waitForListenerRegistration()

        let event = PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented)
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: nil)
        waitForEventDispatch()

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

    func testBothSpecificAndOnAnyHandlersFire() {
        var openCount = 0
        var anyCount = 0

        let handlers = PaywallEventHandlers()
            .onOpen { _ in openCount += 1 }
            .onAnyEvent { _ in anyCount += 1 }

        handlers.handleEvent(PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented))
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(anyCount, 1)
    }
}
