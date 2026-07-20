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
        trigger: \(escapingLineBreaks(in: trigger))
        reason: \(content.reasonCode) (\(content.category.reportName))
        sdk: helium-swift \(sdkVersion)
        \(escapingLineBreaks(in: content.title)) — \(escapingLineBreaks(in: content.body))
        """
    }

    /// Triggers are unrestricted developer strings, and body copy interpolates them, so both can
    /// carry line breaks — which would add rows to this line-oriented format and break the parsers
    /// behind it. Reason codes, category names and the SDK version are compile-time values and
    /// need no escaping.
    private func escapingLineBreaks(in value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
