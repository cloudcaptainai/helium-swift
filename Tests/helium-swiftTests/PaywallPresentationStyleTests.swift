import XCTest
import UIKit
@testable import Helium

/// Locks the precedence rule between an integrator-supplied presentation style and the
/// dashboard-configured one, and the UIKit wiring each style resolves to.
@MainActor
final class PaywallPresentationStyleTests: XCTestCase {

    private let allStyles: [HeliumPresentationStyle?] = [
        nil, .slideUp, .slideLeft
    ]

    private func makeViewController() -> UIViewController {
        let viewController = UIViewController()
        viewController.modalPresentationStyle = .fullScreen
        return viewController
    }

    private func apply(
        requested: HeliumPresentationStyle?,
        configured: HeliumPresentationStyle?
    ) -> UIViewController {
        let viewController = makeViewController()
        HeliumPaywallPresenter.shared.applyPresentationStyle(
            requested: requested, configured: configured, to: viewController
        )
        return viewController
    }

    // MARK: - An integrator-supplied style always wins

    func test_GIVEN_integratorRequestedSlideLeft_WHEN_applied_THEN_winsOverEveryConfiguredStyle() {
        for configured in allStyles {
            let viewController = apply(requested: .slideLeft, configured: configured)

            XCTAssertEqual(
                viewController.modalPresentationStyle, .custom,
                "configured: \(String(describing: configured))"
            )
        }
    }

    func test_GIVEN_integratorRequestedSlideUp_WHEN_applied_THEN_winsOverEveryConfiguredStyle() {
        for configured in allStyles {
            let viewController = apply(requested: .slideUp, configured: configured)

            XCTAssertEqual(
                viewController.modalPresentationStyle, .fullScreen,
                "configured: \(String(describing: configured))"
            )
            XCTAssertNil(viewController.transitioningDelegate)
            XCTAssertEqual(viewController.modalTransitionStyle, .coverVertical)
        }
    }

    // MARK: - The dashboard applies when the integrator supplies nothing

    func test_GIVEN_noIntegratorStyle_WHEN_applied_THEN_configuredStyleDrivesPresentation() {
        XCTAssertEqual(apply(requested: nil, configured: .slideLeft).modalPresentationStyle, .custom)
    }

    func test_GIVEN_nothingRequestedOrConfigured_WHEN_applied_THEN_leavesFullScreenBaselineAlone() {
        let viewController = apply(requested: nil, configured: nil)

        XCTAssertEqual(viewController.modalPresentationStyle, .fullScreen)
        XCTAssertNil(viewController.transitioningDelegate)
        XCTAssertEqual(viewController.modalTransitionStyle, .coverVertical)
    }

    // MARK: - UIKit wiring

    func test_GIVEN_slideLeft_WHEN_applied_THEN_usesTheSlideInTransition() {
        let viewController = apply(requested: .slideLeft, configured: nil)

        XCTAssertEqual(viewController.modalPresentationStyle, .custom)
        XCTAssertTrue(viewController.transitioningDelegate is SlideInTransitioningDelegate)
    }

    // MARK: - Default configuration

    /// `presentationStyle` has to stay optional. A concrete default would make every
    /// `PaywallPresentationConfig()` look like an explicit integrator choice, and an integrator
    /// choice always wins, so the dashboard-configured style would become unreachable.
    func test_GIVEN_defaultPresentationConfig_WHEN_read_THEN_presentationStyleIsNilSoDashboardDecides() {
        XCTAssertNil(PaywallPresentationConfig().presentationStyle)
    }
}
