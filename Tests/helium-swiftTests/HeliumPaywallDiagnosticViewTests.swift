import XCTest
@testable import Helium

/// The modal has two entry points: the paywall-not-shown path, where nothing rendered, and the
/// fallback banner, where a fallback paywall is on screen behind it. `usersWillSee` is authored for
/// the first, so the modal resolves it against the entry point it was opened from.
final class HeliumPaywallDiagnosticViewTests: XCTestCase {

    private let mapper = DiagnosticContentMapper()
    private let trigger = "onboarding_end"

    private func modal(
        for reason: PaywallUnavailableReason,
        fallbackShown: Bool
    ) -> HeliumPaywallDiagnosticView {
        HeliumPaywallDiagnosticView(
            content: mapper.mapUnavailable(reason, context: DiagnosticContext(trigger: trigger)),
            triggerName: trigger,
            fallbackShown: fallbackShown,
            onDismiss: {}
        )
    }

    func testOutcomeIsStatedWhenNothingRendered() {
        XCTAssertEqual(
            modal(for: .forceShowFallback, fallbackShown: false).usersWillSeeText,
            "The bundled fallback could not be rendered, so this user saw nothing."
        )
    }

    /// That same record reached from the banner would tell a developer their fallback failed to
    /// render while they are looking at it.
    func testOutcomeIsWithheldWhenAFallbackIsOnScreen() {
        XCTAssertNil(modal(for: .forceShowFallback, fallbackShown: true).usersWillSeeText)
    }

    /// No reason is exempt. Every authored outcome describes a user who got no paywall, so a
    /// rendered fallback disproves all of them.
    func testNoReasonStatesAnOutcomeOverAFallback() {
        for reason in PaywallUnavailableReason.allCases {
            XCTAssertNil(
                modal(for: reason, fallbackShown: true).usersWillSeeText,
                "\(reason.rawValue) states an outcome over a rendered fallback"
            )
        }
    }
}
