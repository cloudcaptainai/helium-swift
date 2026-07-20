//
//  DiagnosticContext.swift
//  Helium
//

import Foundation

/// The runtime facts the copy matrix needs beyond the reason itself.
///
/// Passed in rather than read from global state inside the mapper, so the whole copy matrix stays
/// a pure function and is unit-testable without a fetched config.
struct DiagnosticContext {
    let trigger: String

    /// Deep-links the paywall editor CTA straight to the offending paywall when it resolves.
    let paywallId: String?

    /// The web checkout processors currently enabled, so the web-checkout copy can name them.
    /// Carried as the typed set; how (and whether) to render it is the mapper's decision.
    let webCheckoutProcessors: WebCheckoutProcessors

    init(trigger: String, paywallId: String? = nil, webCheckoutProcessors: WebCheckoutProcessors = []) {
        self.trigger = trigger
        self.paywallId = paywallId
        self.webCheckoutProcessors = webCheckoutProcessors
    }

    /// Resolves the context from live SDK state. The paywall id is best-effort: an unresolvable
    /// trigger simply leaves the CTA pointing at the paywall list.
    static func live(trigger: String) -> DiagnosticContext {
        DiagnosticContext(
            trigger: trigger,
            paywallId: HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)?.paywallUUID,
            webCheckoutProcessors: Helium.config.webCheckoutProcessors
        )
    }
}
