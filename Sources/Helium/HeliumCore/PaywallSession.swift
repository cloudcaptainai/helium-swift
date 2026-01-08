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
    
    var paywallInfo: HeliumPaywallInfo?
    
    init(trigger: String, paywallInfo: HeliumPaywallInfo?) {
        self.sessionId = UUID().uuidString
        self.trigger = trigger
        self.paywallInfo = paywallInfo
    }
}
