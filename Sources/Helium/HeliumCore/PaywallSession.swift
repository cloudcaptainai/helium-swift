//
//  PaywallSession.swift
//  Helium
//
//  Represents a single paywall presentation session.
//

import Foundation

/// Represents a single paywall presentation session.
struct PaywallSession {
    let sessionId: String
    let trigger: String
    
    init(trigger: String) {
        self.sessionId = UUID().uuidString
        self.trigger = trigger
    }
}
