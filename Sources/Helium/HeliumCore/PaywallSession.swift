//
//  PaywallSession.swift
//  Helium
//
//  Represents a single paywall presentation session.
//  Sessions are keyed by sessionId (UUID).
//

import Foundation

/// Represents a single paywall presentation session.
/// Each paywall presentation gets its own session, identified by a unique sessionId.
public struct PaywallSession {
    /// Unique identifier for this session
    public let sessionId: String
    
    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}
