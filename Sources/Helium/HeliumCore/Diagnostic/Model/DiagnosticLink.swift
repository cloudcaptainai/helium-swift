//
//  DiagnosticLink.swift
//  Helium
//

import Foundation

/// A labelled destination rendered alongside diagnostic prose.
///
/// The URL is carried as a `String` for the same reason `DiagnosticCta` carries one: the copy matrix
/// never has to parse a URL, and no code path force-unwraps one. The presentation layer converts it
/// once and ignores an unopenable link.
struct DiagnosticLink: Equatable {
    let label: String
    let url: String
}
