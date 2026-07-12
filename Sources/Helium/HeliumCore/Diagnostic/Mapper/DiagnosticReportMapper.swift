//
//  DiagnosticReportMapper.swift
//  Helium
//

import Foundation

/// Projects diagnostic content onto the plain-text report a developer copies to the clipboard and
/// sends to Helium support.
///
/// The format is shared verbatim with the Android SDK, so support tooling can parse either.
struct DiagnosticReportMapper {

    func map(_ content: DiagnosticContent, trigger: String, sdkVersion: String) -> String {
        """
        Helium paywall diagnostic
        trigger: \(trigger)
        reason: \(content.reasonCode) (\(content.category.reportName))
        sdk: helium-swift \(sdkVersion)
        \(content.title) — \(content.body)
        """
    }
}
