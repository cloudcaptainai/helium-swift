import XCTest
@testable import Helium

final class PaywallEventHandlersBuilderTests: XCTestCase {

    func testBuilderChainingCreatesHandlers() {
        var openFired = false
        var closeFired = false
        var dismissedFired = false
        var purchaseFired = false
        var customFired = false
        var anyFired = false

        let handlers = PaywallEventHandlers()
            .onOpen { _ in openFired = true }
            .onClose { _ in closeFired = true }
            .onDismissed { _ in dismissedFired = true }
            .onPurchaseSucceeded { _ in purchaseFired = true }
            .onCustomPaywallAction { _ in customFired = true }
            .onAnyEvent { _ in anyFired = true }

        handlers.handleEvent(PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented))
        XCTAssertTrue(openFired)
        XCTAssertTrue(anyFired)

        handlers.handleEvent(PaywallCloseEvent(triggerName: "t", paywallName: "p"))
        XCTAssertTrue(closeFired)

        handlers.handleEvent(PaywallDismissedEvent(triggerName: "t", paywallName: "p"))
        XCTAssertTrue(dismissedFired)

        handlers.handleEvent(PurchaseSucceededEvent(productId: "prod", triggerName: "t", paywallName: "p", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil))
        XCTAssertTrue(purchaseFired)

        handlers.handleEvent(CustomPaywallActionEvent(actionName: "act", params: [:], triggerName: "t", paywallName: "p"))
        XCTAssertTrue(customFired)
    }

    func testWithHandlersStaticMethod() {
        var openFired = false
        var purchaseFired = false

        let handlers = PaywallEventHandlers.withHandlers(
            onOpen: { _ in openFired = true },
            onPurchaseSucceeded: { _ in purchaseFired = true }
        )

        handlers.handleEvent(PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented))
        XCTAssertTrue(openFired)

        handlers.handleEvent(PurchaseSucceededEvent(productId: "prod", triggerName: "t", paywallName: "p", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil))
        XCTAssertTrue(purchaseFired)
    }

    func testDefaultHandlersAreNil() {
        let handlers = PaywallEventHandlers()
        XCTAssertNil(handlers.onOpen)
        XCTAssertNil(handlers.onClose)
        XCTAssertNil(handlers.onDismissed)
        XCTAssertNil(handlers.onPurchaseSucceeded)
        XCTAssertNil(handlers.onCustomPaywallAction)
        XCTAssertNil(handlers.onAnyEvent)
    }

    func testHandleEventRoutesToCorrectHandler() {
        var openCount = 0
        var closeCount = 0
        var dismissCount = 0

        let handlers = PaywallEventHandlers()
            .onOpen { _ in openCount += 1 }
            .onClose { _ in closeCount += 1 }
            .onDismissed { _ in dismissCount += 1 }

        handlers.handleEvent(PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented))
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(dismissCount, 0)

        handlers.handleEvent(PaywallCloseEvent(triggerName: "t", paywallName: "p"))
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(dismissCount, 0)
    }

    func testOnAnyEventSkipsNonPaywallContextEvents() {
        var anyEventCount = 0

        let handlers = PaywallEventHandlers()
            .onAnyEvent { _ in anyEventCount += 1 }

        // PaywallSkippedEvent is HeliumEvent but NOT PaywallContextEvent
        handlers.handleEvent(PaywallSkippedEvent(triggerName: "t"))
        XCTAssertEqual(anyEventCount, 0, "onAnyEvent should NOT fire for non-PaywallContextEvent")

        // PaywallOpenEvent IS a PaywallContextEvent
        handlers.handleEvent(PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented))
        XCTAssertEqual(anyEventCount, 1, "onAnyEvent should fire for PaywallContextEvent")
    }

    func testBothSpecificAndOnAnyHandlersFire() {
        var openFired = false
        var anyFired = false

        let handlers = PaywallEventHandlers()
            .onOpen { _ in openFired = true }
            .onAnyEvent { _ in anyFired = true }

        handlers.handleEvent(PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented))
        XCTAssertTrue(openFired)
        XCTAssertTrue(anyFired)
    }
}
