import Foundation

/// Sendable extract of `PaywallSession` — the session carries non-Sendable
/// closures (event handlers), so it can't cross actor boundaries directly.
struct PaywallObservabilityScope: Sendable {
    let sessionId: String
    let trigger: String
    let paywallUUID: String?
}

extension PaywallSession {
    var observabilityScope: PaywallObservabilityScope {
        PaywallObservabilityScope(
            sessionId: sessionId,
            trigger: trigger,
            paywallUUID: paywallInfoWithBackups?.paywallUUID
        )
    }
}
