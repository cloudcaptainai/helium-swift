import XCTest
@testable import Helium

final class HeliumDiagnosticGateTests: XCTestCase {

    /// A reason that is never suppressed, so each test isolates the gate under exercise.
    private let showableReason = PaywallUnavailableReason.triggerHasNoPaywall

    private func shouldShow(
        reason: PaywallUnavailableReason? = nil,
        fallbackShown: Bool = false,
        isPreviewTrigger: Bool = false,
        isDebugBuild: Bool = false,
        environment: AppReceiptsHelper.Environment = .debug,
        displayEnabled: Bool = true,
        enabledInTestFlight: Bool = true,
        serverFlagEnabled: Bool = true,
        doNotShowAgain: @escaping () -> Bool = { false }
    ) -> Bool {
        HeliumDiagnosticGate.shouldShow(
            unavailableReason: reason ?? showableReason,
            fallbackShown: fallbackShown,
            isPreviewTrigger: isPreviewTrigger,
            isDebugBuild: isDebugBuild,
            environment: environment,
            displayEnabled: displayEnabled,
            enabledInTestFlight: enabledInTestFlight,
            serverFlagEnabled: serverFlagEnabled,
            doNotShowAgain: doNotShowAgain
        )
    }

    // MARK: - Suppression

    /// A paywall is already on screen, so a modal would cover the thing under inspection.
    func testAlreadyPresentedNeverShows() {
        XCTAssertFalse(shouldShow(reason: .alreadyPresented))
    }

    func testAlreadyPresentedIsSuppressedEvenForThePreviewTrigger() {
        XCTAssertFalse(shouldShow(reason: .alreadyPresented, isPreviewTrigger: true))
    }

    /// A failed second try leaves a dead button behind a live paywall, and a forced fallback that
    /// didn't render leaves a blank screen. Both are worth interrupting for.
    func testSecondTryMissAndForcedFallbackShow() {
        XCTAssertTrue(shouldShow(reason: .secondTryNoMatch))
        XCTAssertTrue(shouldShow(reason: .forceShowFallback))
    }

    func testOnlyAlreadyPresentedIsSuppressed() {
        let suppressed = PaywallUnavailableReason.allCases.filter { !shouldShow(reason: $0) }

        XCTAssertEqual(suppressed, [.alreadyPresented])
    }

    /// A skip passes a nil reason and is never suppressed.
    func testSkipIsNotSuppressed() {
        XCTAssertTrue(
            HeliumDiagnosticGate.shouldShow(
                unavailableReason: nil,
                fallbackShown: false,
                isPreviewTrigger: false,
                isDebugBuild: true,
                environment: .debug,
                displayEnabled: true,
                enabledInTestFlight: true,
                serverFlagEnabled: true,
                doNotShowAgain: { false }
            )
        )
    }

    // MARK: - Modal / badge exclusivity

    /// The invariant that makes the modal's "no fallback was available" copy truthful.
    func testARenderedFallbackNeverShowsTheModal() {
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

    /// An App Store build structurally cannot show the modal.
    func testProductionNeverShows() {
        XCTAssertFalse(shouldShow(environment: .production))
        XCTAssertFalse(shouldShow(environment: .production, enabledInTestFlight: true))
    }

    func testTestFlightShowsOnlyWhenOptedIn() {
        XCTAssertTrue(shouldShow(environment: .sandbox, enabledInTestFlight: true))
        XCTAssertFalse(shouldShow(environment: .sandbox, enabledInTestFlight: false))
    }

    /// A .debug receipt environment without a DEBUG-compiled build — a release-configuration
    /// simulator run — is gated by the same opt-in as TestFlight.
    func testDebugEnvironmentInAReleaseBuildRequiresTheOptIn() {
        XCTAssertTrue(shouldShow(isDebugBuild: false, environment: .debug, enabledInTestFlight: true))
        XCTAssertFalse(shouldShow(isDebugBuild: false, environment: .debug, enabledInTestFlight: false))
    }

    /// Leaving the TestFlight opt-in off must not silence DEBUG-build diagnostics.
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
    /// is ever read.
    func testAnEarlierClosedGateNeverReadsTheDevicePref() {
        var reads = 0
        let counting: () -> Bool = { reads += 1; return false }

        _ = shouldShow(reason: .alreadyPresented, doNotShowAgain: counting)
        _ = shouldShow(fallbackShown: true, doNotShowAgain: counting)
        _ = shouldShow(displayEnabled: false, doNotShowAgain: counting)
        _ = shouldShow(environment: .production, doNotShowAgain: counting)
        _ = shouldShow(serverFlagEnabled: false, doNotShowAgain: counting)
        // The preview bypass opens the gate without consulting the preference either.
        _ = shouldShow(isPreviewTrigger: true, doNotShowAgain: counting)

        XCTAssertEqual(reads, 0)
    }
}
