//
//  HeliumDiagnosticGate.swift
//  Helium
//

import Foundation

/// Decides whether the paywall diagnostic modal may be presented for a given reason.
///
/// Pure by design — every input is passed in, so the full visibility matrix is unit-testable
/// without a live SDK. The caller owns the singleton presentation guard, which has to be a claim
/// rather than a predicate.
enum HeliumDiagnosticGate {

    /// UserDefaults key for the per-device "do not show again" preference the gate evaluates.
    /// The modal's toggle writes it; `shouldShow` callers read it.
    static let doNotShowAgainKey = "heliumDiagnosticDoNotShowAgain"

    /// Reasons that are logged but never surfaced as a modal.
    ///
    /// Only `.alreadyPresented` qualifies: a Helium paywall is literally on screen, so a modal would
    /// cover the very thing the developer asked to see, and there is nothing to act on. Every other
    /// reason means the developer is owed an explanation — including a failed second try, which fires
    /// while a paywall is on screen but leaves a dead button behind it.
    static let suppressedReasons: Set<PaywallUnavailableReason> = [.alreadyPresented]

    /// - Parameters:
    ///   - unavailableReason: the reason a paywall was unavailable, or `nil` for a skip (a skip is
    ///     never suppressed).
    ///   - fallbackShown: whether a fallback rendered. A rendered fallback is the badge's territory,
    ///     not the modal's — the two are mutually exclusive, and that is what makes the modal's "no
    ///     fallback was available, so this user saw nothing" copy truthful.
    ///   - isPreviewTrigger: dashboard paywall previews bypass the flag, environment and
    ///     do-not-show gates, but not suppression.
    ///   - environment: debug always shows; sandbox (TestFlight, and Xcode-installed release
    ///     builds) requires the opt-in; an App Store build structurally cannot show the modal.
    ///   - displayEnabled: the public master flag.
    ///   - enabledInTestFlight: the public TestFlight opt-in.
    ///   - serverFlagEnabled: the server-side kill switch.
    ///   - doNotShowAgain: the per-device developer preference. Evaluated last and only if every
    ///     other gate opens, so builds that can never show the modal do not pay to read it.
    static func shouldShow(
        unavailableReason: PaywallUnavailableReason?,
        fallbackShown: Bool,
        isPreviewTrigger: Bool,
        environment: AppReceiptsHelper.Environment,
        displayEnabled: Bool,
        enabledInTestFlight: Bool,
        serverFlagEnabled: Bool,
        doNotShowAgain: () -> Bool
    ) -> Bool {
        if fallbackShown { return false }
        if let unavailableReason, suppressedReasons.contains(unavailableReason) { return false }
        if isPreviewTrigger { return true }
        guard displayEnabled else { return false }
        guard isVisible(in: environment, enabledInTestFlight: enabledInTestFlight) else { return false }
        guard serverFlagEnabled else { return false }
        return !doNotShowAgain()
    }

    private static func isVisible(
        in environment: AppReceiptsHelper.Environment,
        enabledInTestFlight: Bool
    ) -> Bool {
        switch environment {
        case .debug: return true
        case .sandbox: return enabledInTestFlight
        case .production: return false
        }
    }
}
