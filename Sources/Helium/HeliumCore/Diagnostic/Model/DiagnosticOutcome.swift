//
//  DiagnosticOutcome.swift
//  Helium
//

import Foundation

/// Why Helium had no paywall to show, in the two shapes the SDK reports.
///
/// The distinction drives more than copy: a skip is Helium working as configured, so it warrants a
/// far quieter response than a paywall that was meant to appear and didn't.
enum DiagnosticOutcome {

    /// A paywall was meant to show and could not. The reason is optional because the failing path
    /// cannot always name one.
    case unavailable(PaywallUnavailableReason?)

    /// Helium deliberately chose not to show a paywall.
    case skipped(PaywallSkippedReason)
}
