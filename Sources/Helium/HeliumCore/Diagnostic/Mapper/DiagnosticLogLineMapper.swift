//
//  DiagnosticLogLineMapper.swift
//  Helium
//

import Foundation

/// Projects diagnostic content onto the single log line the SDK emits for it.
///
/// The line re-appends the CTA's URL so log output stays as actionable as the modal, and leads with
/// the bracketed reason code so it remains greppable.
struct DiagnosticLogLineMapper {

    func map(_ content: DiagnosticContent) -> String {
        var line = "[\(content.reasonCode)] \(content.title). \(content.body)"
        if case let .openUrl(_, url) = content.cta {
            line += " \(url)"
        }
        return line
    }
}
