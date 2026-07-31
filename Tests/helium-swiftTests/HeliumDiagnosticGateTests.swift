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
        serverAllowsInTestFlight: () -> Bool = { true },
        doNotShowAgain: () -> Bool = { false }
    ) -> Bool {
        HeliumDiagnosticGate.shouldShow(
            outcome: outcome ?? showableOutcome,
            fallbackShown: fallbackShown,
            isPreviewTrigger: isPreviewTrigger,
            isDebugBuild: isDebugBuild,
            environment: environment,
            displayEnabled: displayEnabled,
            serverAllowsInTestFlight: serverAllowsInTestFlight(),
            doNotShowAgain: doNotShowAgain()
        )
    }

    private func isEnabled(
        isPreviewTrigger: Bool = false,
        isDebugBuild: Bool = false,
        environment: AppReceiptsHelper.Environment = .debug,
        displayEnabled: Bool = true,
        serverAllowsInTestFlight: () -> Bool = { true }
    ) -> Bool {
        HeliumDiagnosticGate.isEnabled(
            isPreviewTrigger: isPreviewTrigger,
            isDebugBuild: isDebugBuild,
            environment: environment,
            displayEnabled: displayEnabled,
            serverAllowsInTestFlight: serverAllowsInTestFlight()
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

    /// A skip is Helium working as configured, but a trigger that silently shows nothing reads as
    /// breakage, so it is explained wherever failures are.
    func testSkipsShowWhereverFailuresDo() {
        for reason in PaywallSkippedReason.allCases {
            XCTAssertTrue(
                shouldShow(outcome: .skipped(reason), isDebugBuild: true),
                "Expected \(reason.rawValue) to show in a debug build"
            )
            XCTAssertTrue(
                shouldShow(outcome: .skipped(reason), isDebugBuild: false, environment: .sandbox),
                "Expected \(reason.rawValue) to show in TestFlight"
            )
        }
    }

    func testSkipsHonourTheDoNotShowAgainCheckbox() {
        XCTAssertFalse(shouldShow(outcome: .skipped(.alreadyEntitled), doNotShowAgain: { true }))
    }

    func testSkipsStillExplainThemselvesInADashboardPreview() {
        XCTAssertTrue(shouldShow(outcome: .skipped(.alreadyEntitled), isPreviewTrigger: true))
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
                serverAllowsInTestFlight: { false },
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
        XCTAssertFalse(shouldShow(environment: .production, serverAllowsInTestFlight: { true }))
    }

    func testTestFlightShowsOnlyWhenTheServerAllowsIt() {
        XCTAssertTrue(shouldShow(environment: .sandbox, serverAllowsInTestFlight: { true }))
        XCTAssertFalse(shouldShow(environment: .sandbox, serverAllowsInTestFlight: { false }))
    }

    /// A .debug environment without a DEBUG-compiled build is a release-configuration run by a
    /// developer: a simulator, or a device launched from Xcode.
    func testDebugEnvironmentInAReleaseBuildRequiresTheServerPermission() {
        XCTAssertTrue(shouldShow(isDebugBuild: false, environment: .debug, serverAllowsInTestFlight: { true }))
        XCTAssertFalse(shouldShow(isDebugBuild: false, environment: .debug, serverAllowsInTestFlight: { false }))
    }

    // MARK: - Server permission

    func testTheServerFlagClosesBuildsThatAreNotDebug() {
        XCTAssertFalse(shouldShow(serverAllowsInTestFlight: { false }))
        XCTAssertFalse(shouldShow(environment: .sandbox, serverAllowsInTestFlight: { false }))
    }

    /// The remote permission exists to keep a developer modal out of a tester's hands. A developer
    /// running their own debug build is not a tester, so nothing remote can take the fallback badge
    /// or the modal it opens away from them.
    func testTheServerFlagDoesNotReachDebugBuilds() {
        XCTAssertTrue(shouldShow(isDebugBuild: true, serverAllowsInTestFlight: { false }))
        XCTAssertTrue(isEnabled(isDebugBuild: true, serverAllowsInTestFlight: { false }))
        XCTAssertTrue(
            isEnabled(
                isDebugBuild: true,
                environment: .sandbox,
                serverAllowsInTestFlight: { false }
            )
        )
    }

    func testTheSdkFlagIsTheOnlyThingThatClosesADebugBuild() {
        XCTAssertFalse(
            shouldShow(isDebugBuild: true, displayEnabled: false, serverAllowsInTestFlight: { false })
        )
        XCTAssertFalse(isEnabled(isDebugBuild: true, displayEnabled: false))
    }

    /// Reading the permission takes a lock a paywall render should never wait on, so every gate that
    /// can answer without it has to.
    func testAGateThatCanAnswerWithoutTheServerFlagNeverReadsIt() {
        var reads = 0
        let counting: () -> Bool = { reads += 1; return true }

        _ = isEnabled(isDebugBuild: true, serverAllowsInTestFlight: counting)
        _ = isEnabled(displayEnabled: false, serverAllowsInTestFlight: counting)
        _ = isEnabled(environment: .production, serverAllowsInTestFlight: counting)
        _ = isEnabled(isPreviewTrigger: true, serverAllowsInTestFlight: counting)
        _ = shouldShow(isDebugBuild: true, serverAllowsInTestFlight: counting)

        XCTAssertEqual(reads, 0)
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
        _ = shouldShow(fallbackShown: true, doNotShowAgain: counting)
        _ = shouldShow(displayEnabled: false, doNotShowAgain: counting)
        _ = shouldShow(environment: .production, doNotShowAgain: counting)
        _ = shouldShow(serverAllowsInTestFlight: { false }, doNotShowAgain: counting)
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
        XCTAssertFalse(isEnabled(environment: .sandbox, serverAllowsInTestFlight: { false }))
        XCTAssertFalse(isEnabled(serverAllowsInTestFlight: { false }))
    }

    func testDeliberatePathShowsWhenEveryPreferenceAllowsIt() {
        XCTAssertTrue(isEnabled())
        XCTAssertTrue(isEnabled(isDebugBuild: true))
        XCTAssertTrue(isEnabled(environment: .sandbox, serverAllowsInTestFlight: { true }))
    }

    func testDeliberatePathKeepsThePreviewBypass() {
        XCTAssertTrue(
            isEnabled(
                isPreviewTrigger: true,
                environment: .production,
                displayEnabled: false,
                serverAllowsInTestFlight: { false }
            )
        )
    }
}
