//
//  DiagnosticCta.swift
//  Helium
//

import Foundation

/// The diagnostic modal's single primary action.
///
/// Authored per reason rather than inferred from body text, which is what allows body copy to stay
/// free of URLs — and what removes the need to detect a URL inside prose.
///
/// The URL is carried as a `String` so the copy matrix never has to parse one, and so no code path
/// force-unwraps a `URL`. The presentation layer converts it once and ignores an unopenable link.
enum DiagnosticCta: Equatable {
    /// Opens `url`; the modal offers a copy-URL affordance alongside it.
    case openUrl(label: String, url: String)

    case copyUrl(label: String, url: String)

    /// Copies the diagnostic report. Used where no useful destination URL exists.
    case copyReport

    var url: String? {
        switch self {
        case let .openUrl(_, url), let .copyUrl(_, url): return url
        case .copyReport: return nil
        }
    }
}
