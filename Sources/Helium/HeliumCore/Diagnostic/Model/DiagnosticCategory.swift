//
//  DiagnosticCategory.swift
//  Helium
//

import Foundation

/// Severity grouping for a paywall-unavailable reason, keyed by *who fixes it* rather than by
/// where the failure occurred.
///
/// `bannerLabel` is displayed copy; `reportName` is the stable token written into the diagnostic
/// report, and is shared verbatim with the Android SDK.
enum DiagnosticCategory {
    case expected
    case setup
    case network
    case integrationError

    var bannerLabel: String {
        switch self {
        case .expected: return "WORKING AS CONFIGURED"
        case .setup: return "SETUP NEEDED"
        case .network: return "NETWORK / TIMING"
        case .integrationError: return "INTEGRATION ERROR"
        }
    }

    var reportName: String {
        switch self {
        case .expected: return "expected"
        case .setup: return "setup"
        case .network: return "network"
        case .integrationError: return "integrationError"
        }
    }
}
