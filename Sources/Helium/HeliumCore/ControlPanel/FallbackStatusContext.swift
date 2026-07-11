import Foundation

/// Raw facts about the fallback paywall a triple tap was performed on, captured at the presentation
/// that received the gesture and handed to the control panel.
///
/// A presentation is the only place that unambiguously knows which paywall was tapped — an app can
/// host several at once — so the panel never re-derives this from global SDK state. The bundle
/// status is the resolution that selected the rendered paywall, captured when it was made, so it
/// still describes the tapped presentation even if the bundle reloads while the panel is open.
struct FallbackStatusContext: Equatable {
    let requestedTrigger: String
    /// Why a fallback paywall rendered in place of the live remote paywall.
    let reason: PaywallUnavailableReason
    let bundleStatus: FallbackBundleStatus
}

extension FallbackStatusContext {

    static let disclaimer = "You're viewing a fallback paywall"

    /// Shows the raw reason key on purpose: this is a developer surface, and the raw key is what
    /// appears in logs and paywall events.
    var reasonLine: String {
        "Reason: \(reason.rawValue)"
    }

    var requestedTriggerLine: String {
        "Requested trigger: \(requestedTrigger)"
    }

    /// Shows the raw default-entry key on purpose: this is a developer surface, and the raw key is
    /// what appears in logs and in the bundle JSON.
    var resolvedEntryLine: String {
        switch bundleStatus.resolvedEntry {
        case .triggerOwnEntry:
            return "Resolved from this trigger's own fallback entry"
        case .defaultEntry:
            return "Resolved from the default fallback entry (\(bundleStatus.resolvedTrigger))"
        }
    }

    var servingPaywallLine: String {
        "Serving paywall: \(bundleStatus.paywallTemplateName ?? "Unknown paywall")"
    }

    var configuredBundleLine: String {
        bundleStatus.configuredTriggerCount == 1
            ? "Fallback bundle configured with 1 trigger"
            : "Fallback bundle configured with \(bundleStatus.configuredTriggerCount) triggers"
    }
}
