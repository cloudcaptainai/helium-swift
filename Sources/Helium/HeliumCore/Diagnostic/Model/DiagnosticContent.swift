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
struct DiagnosticContent: Equatable {
    let category: DiagnosticCategory
    let title: String
    let body: String
    let usersWillSee: String
    let cta: DiagnosticCta
    let reasonCode: String
}
