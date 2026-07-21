//
//  DiagnosticLogLineMapper.swift
//  Helium
//

import Foundation

/// Projects diagnostic content onto the single log line the SDK emits for it.
///
/// The line re-appends one URL so log output stays as actionable as the modal, preferring the CTA's
/// destination and otherwise the remediation link, and leads with the bracketed reason code so it
/// remains greppable. Capping it at one keeps every line the same shape.
struct DiagnosticLogLineMapper {

    func map(_ content: DiagnosticContent) -> String {
        var line = "[\(content.reasonCode)] \(content.title). \(content.body)"
        if case let .openUrl(_, url) = content.cta {
            line += " \(url)"
        } else if let link = content.usersWillSeeLink {
            line += " \(link.url)"
        }
        return line
    }
}
