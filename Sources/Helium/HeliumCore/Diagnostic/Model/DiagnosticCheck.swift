//
//  DiagnosticCheck.swift
//  Helium
//

import Foundation

struct DiagnosticCheck: Equatable {
    enum Verdict: Equatable {
        case passed
        case failed
        case checkedByServer
    }

    let label: String
    let verdict: Verdict
}
