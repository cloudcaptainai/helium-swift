//
//  DiagnosticContent.swift
//  Helium
//

import Foundation

/// The authored copy describing one reason a paywall was not shown.
///
/// A pure model: rendering it as a log line or as a support report belongs to the corresponding
/// mappers, so the same content can be projected into either without this type knowing about them.
///
/// `usersWillSee` is a required field rather than a sentence buried in `body` so that every reason
/// is forced to answer the question a tester actually has: did real customers get a broken
/// experience?
///
/// Its remediation pointer is a structured `usersWillSeeLink` rather than a URL inside that prose,
/// so each surface renders it in its own idiom instead of detecting one in text.
struct DiagnosticContent: Equatable {
    let category: DiagnosticCategory
    let title: String
    let body: String
    let usersWillSee: String
    let usersWillSeeLink: DiagnosticLink?
    let cta: DiagnosticCta
    let reasonCode: String
}
