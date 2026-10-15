import XCTest
@testable import Helium

final class DuplicatePresentationTests: HeliumTestCase {

    private func openFailures(_ reason: PaywallUnavailableReason) -> [PaywallOpenFailedEvent] {
        mockDelegate.receivedEvents
            .compactMap { $0 as? PaywallOpenFailedEvent }
            .filter { $0.paywallUnavailableReason == reason }
    }

    private func waitForPresentationsToEnd(count: Int) {
        waitForEventDispatch { self.openFailures(.notInitialized).count == count }
    }

    func testSecondPresentWhileFirstIsInFlightIsRejected() {
        let presenter = HeliumPaywallPresenter.shared
        presenter.presentUpsellWithLoadingBudget(trigger: "dup_trigger", presentationContext: .empty)
        presenter.presentUpsellWithLoadingBudget(trigger: "dup_trigger", presentationContext: .empty)

        waitForPresentationsToEnd(count: 1)

        XCTAssertEqual(openFailures(.alreadyPresented).count, 1)
        XCTAssertEqual(openFailures(.notInitialized).count, 1)
    }

    func testPresentIsAllowedAgainOnceTheFirstPresentationEnds() {
        let presenter = HeliumPaywallPresenter.shared
        presenter.presentUpsellWithLoadingBudget(trigger: "dup_trigger", presentationContext: .empty)
        waitForPresentationsToEnd(count: 1)

        presenter.presentUpsellWithLoadingBudget(trigger: "dup_trigger", presentationContext: .empty)
        waitForPresentationsToEnd(count: 2)

        XCTAssertTrue(openFailures(.alreadyPresented).isEmpty)
        XCTAssertEqual(openFailures(.notInitialized).count, 2)
    }
}
