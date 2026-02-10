import XCTest
@testable import Helium

final class PaywallSkipTests: HeliumTestCase {

    func testSkipPaywallFiresSkippedEvent() {
        let paywallInfo = makeTestPaywallInfo(trigger: "skip_trigger", shouldShow: false)
        let config = makeTestConfig(triggers: ["skip_trigger": paywallInfo])
        injectConfig(config)

        let context = PaywallPresentationContext.empty
        let skipped = Helium.shared.skipPaywallIfNeeded(trigger: "skip_trigger", presentationContext: context)
        XCTAssertTrue(skipped)

        waitForEventDispatch {
            self.mockDelegate.receivedEvents.contains { $0 is PaywallSkippedEvent }
        }

        // Check delegate received the event
        let skippedEvents = mockDelegate.receivedEvents.compactMap { $0 as? PaywallSkippedEvent }
        XCTAssertEqual(skippedEvents.count, 1)
        XCTAssertEqual(skippedEvents.first?.triggerName, "skip_trigger")
    }

    func testSkipPaywallCallsOnPaywallNotShown() {
        let paywallInfo = makeTestPaywallInfo(trigger: "skip_trigger", shouldShow: false)
        let config = makeTestConfig(triggers: ["skip_trigger": paywallInfo])
        injectConfig(config)

        var notShownReason: PaywallNotShownReason?
        let context = PaywallPresentationContext(
            config: PaywallPresentationConfig(),
            eventHandlers: nil,
            onEntitled: nil,
            onPaywallNotShown: { reason in notShownReason = reason }
        )

        let skipped = Helium.shared.skipPaywallIfNeeded(trigger: "skip_trigger", presentationContext: context)
        XCTAssertTrue(skipped)
        XCTAssertEqual(notShownReason, .targetingHoldout)
    }

    func testNoSkipWhenShouldShowIsTrue() {
        let paywallInfo = makeTestPaywallInfo(trigger: "show_trigger", shouldShow: true)
        let config = makeTestConfig(triggers: ["show_trigger": paywallInfo])
        injectConfig(config)

        let skipped = Helium.shared.skipPaywallIfNeeded(trigger: "show_trigger", presentationContext: .empty)
        XCTAssertFalse(skipped)
    }

    func testNoSkipWhenShouldShowIsNil() {
        let paywallInfo = makeTestPaywallInfo(trigger: "nil_trigger", shouldShow: nil)
        let config = makeTestConfig(triggers: ["nil_trigger": paywallInfo])
        injectConfig(config)

        let skipped = Helium.shared.skipPaywallIfNeeded(trigger: "nil_trigger", presentationContext: .empty)
        XCTAssertFalse(skipped)
    }
}
