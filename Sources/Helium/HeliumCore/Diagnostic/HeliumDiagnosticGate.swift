//
//  HeliumDiagnosticGate.swift
//  Helium
//

import Foundation

/// Decides whether the paywall diagnostic modal may be presented.
///
/// Two questions, deliberately separate. `isEnabled` answers whether diagnostics are available on
/// this build and device at all, and governs every surface including ones the developer opens
/// themselves. `shouldShow` adds the rules for interrupting someone unprompted, which is a higher
/// bar: a modal nobody asked for has to be worth the interruption.
enum HeliumDiagnosticGate {

    static let doNotShowAgainKey = "heliumDiagnosticDoNotShowAgain"

    /// A Helium paywall is already on screen, so a modal would cover the very thing the developer
    /// asked to see. Every other failure leaves the developer owed an explanation.
    static let suppressedReasons: Set<PaywallUnavailableReason> = [.alreadyPresented]

    /// Whether an unprompted modal is warranted for this outcome.
    static func shouldShow(
        outcome: DiagnosticOutcome,
        fallbackShown: Bool,
        isPreviewTrigger: Bool,
        isDebugBuild: Bool,
        environment: AppReceiptsHelper.Environment,
        displayEnabled: Bool,
        serverAllowsInTestFlight: @autoclosure () -> Bool,
        doNotShowAgain: @autoclosure () -> Bool
    ) -> Bool {
        // A rendered fallback paywall disproves the modal's authored outcome, which describes a user
        // who got nothing. That case is surfaced by the on-paywall badge instead.
        if fallbackShown { return false }
        guard warrantsInterrupting(outcome) else { return false }
        guard isEnabled(
            isPreviewTrigger: isPreviewTrigger,
            isDebugBuild: isDebugBuild,
            environment: environment,
            displayEnabled: displayEnabled,
            serverAllowsInTestFlight: serverAllowsInTestFlight()
        ) else { return false }
        if isPreviewTrigger { return true }
        return !doNotShowAgain()
    }

    /// Whether diagnostics are available at all, independent of any single outcome. Also the gate
    /// for a modal the developer opens deliberately, which is why the do-not-show-again preference
    /// is not consulted here: it means stop interrupting me, not never let me look.
    static func isEnabled(
        isPreviewTrigger: Bool,
        isDebugBuild: Bool,
        environment: AppReceiptsHelper.Environment,
        displayEnabled: Bool,
        serverAllowsInTestFlight: @autoclosure () -> Bool
    ) -> Bool {
        if isPreviewTrigger { return true }
        guard displayEnabled else { return false }
        return isAllowedOnThisBuild(
            isDebugBuild: isDebugBuild,
            environment: environment,
            serverAllowsInTestFlight: serverAllowsInTestFlight()
        )
    }

    /// The SDK ships as source, so this resolves against the host app's build configuration.
    static var isDebugBuild: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    /// A skip is Helium working as configured, but from the phone it looks the same as a paywall
    /// that broke: the trigger fired and nothing appeared. It is explained like any failure, and
    /// the do-not-show-again checkbox is the way to quiet it.
    private static func warrantsInterrupting(_ outcome: DiagnosticOutcome) -> Bool {
        switch outcome {
        case .unavailable(let reason):
            guard let reason else { return true }
            return !suppressedReasons.contains(reason)
        case .skipped:
            return true
        }
    }

    /// The server permission exists to keep a developer modal out of a tester's hands, and a
    /// developer running a DEBUG build of their own app is not a tester.
    private static func isAllowedOnThisBuild(
        isDebugBuild: Bool,
        environment: AppReceiptsHelper.Environment,
        serverAllowsInTestFlight: @autoclosure () -> Bool
    ) -> Bool {
        if isDebugBuild { return true }
        switch environment {
        // In a non-DEBUG build, .debug still means a developer's own run: a release-configuration
        // simulator build, or a device launched from Xcode (StoreKit's Xcode environment). It is a
        // release binary all the same, so it answers to the same server permission as TestFlight.
        case .debug, .sandbox: return serverAllowsInTestFlight()
        case .production: return false
        }
    }
}

// MARK: - Live inputs

/// The one place the gate's inputs are bound to live SDK state, so a new input is added once rather
/// than threaded through every call site.
extension HeliumDiagnosticGate {

    static func shouldShowNow(outcome: DiagnosticOutcome, fallbackShown: Bool, trigger: String) -> Bool {
        shouldShow(
            outcome: outcome,
            fallbackShown: fallbackShown,
            isPreviewTrigger: isPreviewTrigger(trigger),
            isDebugBuild: isDebugBuild,
            environment: AppReceiptsHelper.shared.environment,
            displayEnabled: Helium.config.paywallNotShownDiagnosticDisplayEnabled,
            serverAllowsInTestFlight: serverAllowsInTestFlight,
            doNotShowAgain: UserDefaults.standard.bool(forKey: doNotShowAgainKey)
        )
    }

    static func isEnabledNow(trigger: String) -> Bool {
        isEnabled(
            isPreviewTrigger: isPreviewTrigger(trigger),
            isDebugBuild: isDebugBuild,
            environment: AppReceiptsHelper.shared.environment,
            displayEnabled: Helium.config.paywallNotShownDiagnosticDisplayEnabled,
            serverAllowsInTestFlight: serverAllowsInTestFlight
        )
    }

    /// Absent means the server has not said otherwise, so an outcome that fires before the
    /// on-launch response arrives is still explained.
    private static var serverAllowsInTestFlight: Bool {
        HeliumFetchedConfigManager.shared.fetchedConfig?.paywallDiagnosticModalAllowedInTestFlight ?? true
    }

    private static func isPreviewTrigger(_ trigger: String) -> Bool {
        trigger == HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER
    }
}
