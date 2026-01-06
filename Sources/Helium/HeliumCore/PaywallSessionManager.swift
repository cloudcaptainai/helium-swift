//
//  PaywallSessionManager.swift
//  Helium
//
//  Manages paywall sessions with thread-safe operations.
//  Sessions are keyed by sessionId (UUID).
//

import Foundation

/// Manages paywall sessions with thread-safe operations.
///
/// Session lifecycle:
/// 1. `createSession()` - Creates session
/// 2. `removeSession()` - Cleans up after close event is dispatched
public class PaywallSessionManager {
    
    public static let shared = PaywallSessionManager()

    /// Thread-safe storage of sessions keyed by sessionId
    @HeliumAtomic private var sessions: [String: PaywallSession] = [:]
    
    /// Creates a new session.
    /// - Returns: Paywall session ID
    @discardableResult
    public func createSession() -> String {
        let id = UUID().uuidString
        _sessions.withValue { sessions in
            // Don't overwrite if already exists
            guard sessions[id] == nil else { return }
            sessions[id] = PaywallSession(sessionId: id)
        }
        return id
    }
    
    /// Get the session for a sessionId
    /// - Parameter sessionId: The session identifier
    /// - Returns: The session if it exists, nil otherwise
    public func getSession(sessionId: String) -> PaywallSession? {
        return sessions[sessionId]
    }
    
    /// Remove a session
    /// - Parameter sessionId: The session to remove
    public func removeSession(paywallSessionId: String) {
        _sessions.withValue { sessions in
            sessions.removeValue(forKey: paywallSessionId)
        }
    }
    
}
