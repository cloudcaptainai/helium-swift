import XCTest
@testable import Helium

final class HeliumDiagnosticGateTests: XCTestCase {

    /// Never suppressed, so each test isolates the gate under exercise.
    private let showableOutcome = DiagnosticOutcome.unavailable(.triggerHasNoPaywall)

    private func shouldShow(
        outcome: DiagnosticOutcome? = nil,
        fallbackShown: Bool = false,
        isPreviewTrigger: Bool = false,
        isDebugBuild: Bool = false,
        environment: AppReceiptsHelper.Environment = .debug,
        displayEnabled: Bool = true,
        enabledInTestFlight: Bool = true,
        serverFlagEnabled: Bool = true,
        doNotShowAgain: () -> Bool = { false }
    ) -> Bool {
        HeliumDiagnosticGate.shouldShow(
            outcome: outcome ?? showableOutcome,
            fallbackShown: fallbackShown,
            isPreviewTrigger: isPreviewTrigger,
            isDebugBuild: isDebugBuild,
            environment: environment,
            displayEnabled: displayEnabled,
            enabledInTestFlight: enabledInTestFlight,
            serverFlagEnabled: serverFlagEnabled,
            doNotShowAgain: doNotShowAgain()
        )
    }

    private func isEnabled(
        isPreviewTrigger: Bool = false,
        isDebugBuild: Bool = false,
        environment: AppReceiptsHelper.Environment = .debug,
        displayEnabled: Bool = true,
        enabledInTestFlight: Bool = true,
        serverFlagEnabled: Bool = true
    ) -> Bool {
        HeliumDiagnosticGate.isEnabled(
            isPreviewTrigger: isPreviewTrigger,
            isDebugBuild: isDebugBuild,
            environment: environment,
            displayEnabled: displayEnabled,
            enabledInTestFlight: enabledInTestFlight,
            serverFlagEnabled: serverFlagEnabled
        )
    }

    // MARK: - Suppression

    func testAlreadyPresentedNeverShows() {
        XCTAssertFalse(shouldShow(outcome: .unavailable(.alreadyPresented)))
    }

    func testAlreadyPresentedIsSuppressedEvenForThePreviewTrigger() {
        XCTAssertFalse(shouldShow(outcome: .unavailable(.alreadyPresented), isPreviewTrigger: true))
    }

    func testSecondTryMissAndForcedFallbackShow() {
        XCTAssertTrue(shouldShow(outcome: .unavailable(.secondTryNoMatch)))
        XCTAssertTrue(shouldShow(outcome: .unavailable(.forceShowFallback)))
    }

    func testOnlyAlreadyPresentedIsSuppressed() {
        let suppressed = PaywallUnavailableReason.allCases.filter { !shouldShow(outcome: .unavailable($0)) }

        XCTAssertEqual(suppressed, [.alreadyPresented])
    }

    func testAFailureWithNoNamedReasonStillShows() {
        XCTAssertTrue(shouldShow(outcome: .unavailable(nil)))
    }

    // MARK: - Skips

    /// A skip is Helium working as configured, so it is worth a developer's attention but never a
    /// tester's.
    func testSkipsShowInDebugBuildsOnly() {
        for reason in PaywallSkippedReason.allCases {
            XCTAssertTrue(
                shouldShow(outcome: .skipped(reason), isDebugBuild: true),
                "Expected \(reason.rawValue) to show in a debug build"
            )
            XCTAssertFalse(
                shouldShow(outcome: .skipped(reason), isDebugBuild: false, environment: .sandbox),
                "Expected \(reason.rawValue) to stay out of TestFlight"
            )
        }
    }

    func testTheTestFlightOptInDoesNotBringSkipsWithIt() {
        XCTAssertFalse(
            shouldShow(
                outcome: .skipped(.alreadyEntitled),
                isDebugBuild: false,
                environment: .sandbox,
                enabledInTestFlight: true
            )
        )
    }

    func testSkipsStillExplainThemselvesInADashboardPreview() {
        XCTAssertTrue(shouldShow(outcome: .skipped(.alreadyEntitled), isPreviewTrigger: true))
    }

    /// The rule is about skips, not about everything outside a debug build.
    func testAFailureStillShowsOutsideADebugBuild() {
        XCTAssertTrue(shouldShow(isDebugBuild: false, environment: .sandbox))
    }

    // MARK: - Modal / badge exclusivity

    func testARenderedFallbackNeverShowsTheModalUnprompted() {
        XCTAssertFalse(shouldShow(fallbackShown: true))
        XCTAssertFalse(shouldShow(fallbackShown: true, isPreviewTrigger: true))
    }

    // MARK: - Preview bypass

    func testPreviewTriggerShowsEvenWhenEveryOtherGateIsClosed() {
        XCTAssertTrue(
            shouldShow(
                isPreviewTrigger: true,
                environment: .production,
                displayEnabled: false,
                enabledInTestFlight: false,
                serverFlagEnabled: false,
                doNotShowAgain: { true }
            )
        )
    }

    // MARK: - Master flag

    func testMasterFlagOffNeverShows() {
        XCTAssertFalse(shouldShow(displayEnabled: false))
        XCTAssertFalse(shouldShow(environment: .sandbox, displayEnabled: false))
    }

    // MARK: - Build / environment gate

    func testDebugBuildShows() {
        XCTAssertTrue(shouldShow(isDebugBuild: true, environment: .debug))
    }

    func testProductionNeverShows() {
        XCTAssertFalse(shouldShow(environment: .production))
        XCTAssertFalse(shouldShow(environment: .production, enabledInTestFlight: true))
    }

    func testTestFlightShowsOnlyWhenOptedIn() {
        XCTAssertTrue(shouldShow(environment: .sandbox, enabledInTestFlight: true))
        XCTAssertFalse(shouldShow(environment: .sandbox, enabledInTestFlight: false))
    }

    /// A .debug environment without a DEBUG-compiled build is a release-configuration run by a
    /// developer: a simulator, or a device launched from Xcode.
    func testDebugEnvironmentInAReleaseBuildRequiresTheOptIn() {
        XCTAssertTrue(shouldShow(isDebugBuild: false, environment: .debug, enabledInTestFlight: true))
        XCTAssertFalse(shouldShow(isDebugBuild: false, environment: .debug, enabledInTestFlight: false))
    }

    func testTestFlightOptInOffDoesNotAffectDebugBuilds() {
        XCTAssertTrue(shouldShow(isDebugBuild: true, environment: .debug, enabledInTestFlight: false))
    }

    // MARK: - Server kill switch

    func testServerKillSwitchOffNeverShows() {
        XCTAssertFalse(shouldShow(serverFlagEnabled: false))
        XCTAssertFalse(shouldShow(environment: .sandbox, serverFlagEnabled: false))
    }

    // MARK: - Do-not-show-again

    func testDevicePrefSuppresses() {
        XCTAssertFalse(shouldShow(doNotShowAgain: { true }))
    }

    func testEveryGateOpenShows() {
        XCTAssertTrue(shouldShow())
    }

    /// The preference is backed by storage, so an earlier closed gate must short-circuit before it
    /// is read.
    func testAnEarlierClosedGateNeverReadsTheDevicePref() {
        var reads = 0
        let counting: () -> Bool = { reads += 1; return false }

        _ = shouldShow(outcome: .unavailable(.alreadyPresented), doNotShowAgain: counting)
        _ = shouldShow(outcome: .skipped(.alreadyEntitled), doNotShowAgain: counting)
        _ = shouldShow(fallbackShown: true, doNotShowAgain: counting)
        _ = shouldShow(displayEnabled: false, doNotShowAgain: counting)
        _ = shouldShow(environment: .production, doNotShowAgain: counting)
        _ = shouldShow(serverFlagEnabled: false, doNotShowAgain: counting)
        _ = shouldShow(isPreviewTrigger: true, doNotShowAgain: counting)

        XCTAssertEqual(reads, 0)
    }

    // MARK: - Deliberate path

    /// The checkbox means stop interrupting me, not never let me look, so opening the modal from
    /// the fallback badge keeps working after it is ticked.
    func testTheDevicePrefDoesNotCloseTheDeliberatePath() {
        XCTAssertFalse(shouldShow(doNotShowAgain: { true }))
        XCTAssertTrue(isEnabled())
    }

    func testDeliberatePathHonoursEveryOtherStandingPreference() {
        XCTAssertFalse(isEnabled(displayEnabled: false))
        XCTAssertFalse(isEnabled(environment: .production))
        XCTAssertFalse(isEnabled(environment: .sandbox, enabledInTestFlight: false))
        XCTAssertFalse(isEnabled(serverFlagEnabled: false))
    }

    func testDeliberatePathShowsWhenEveryPreferenceAllowsIt() {
        XCTAssertTrue(isEnabled())
        XCTAssertTrue(isEnabled(isDebugBuild: true))
        XCTAssertTrue(isEnabled(environment: .sandbox, enabledInTestFlight: true))
    }

    func testDeliberatePathKeepsThePreviewBypass() {
        XCTAssertTrue(
            isEnabled(
                isPreviewTrigger: true,
                environment: .production,
                displayEnabled: false,
                enabledInTestFlight: false,
                serverFlagEnabled: false
            )
        )
    }
}
