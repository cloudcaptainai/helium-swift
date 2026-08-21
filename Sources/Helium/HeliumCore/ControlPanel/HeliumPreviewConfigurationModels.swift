import Foundation

/// How a preview handles the app2web checkout it kicks out to.
enum HeliumPreviewPurchaseMode: String, CaseIterable, Identifiable {
    case simulated
    case real

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simulated: return "Simulated purchase"
        case .real: return "Real purchase"
        }
    }

    var detail: String {
        switch self {
        case .simulated:
            return "Full checkout UI, no Paddle call. No transaction, no entitlement."
        case .real:
            return "Real Paddle purchase and entitlements, tagged helium_testing."
        }
    }

    var systemImageName: String {
        switch self {
        case .simulated: return "testtube.2"
        case .real: return "creditcard"
        }
    }

    /// Real Paddle checkout is only cleared for US buyers today.
    var isUSOnly: Bool { self == .real }
}

/// A trait or user-attribute override entered for a preview run.
struct HeliumPreviewKeyValue: Identifiable, Equatable {
    let id = UUID()
    var key: String = ""
    var value: String = ""

    var isComplete: Bool {
        !key.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The language a preview renders in. `.device` leaves resolution to the paywall's own logic.
enum HeliumPreviewLanguage: String, CaseIterable, Identifiable {
    case device
    case en
    case es
    case fr
    case de
    case pt_BR = "pt-BR"
    case ja

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .device: return "Device default"
        case .en: return "English"
        case .es: return "Spanish"
        case .fr: return "French"
        case .de: return "German"
        case .pt_BR: return "Portuguese (Brazil)"
        case .ja: return "Japanese"
        }
    }

    var summary: String {
        self == .device ? "Device default" : "\(displayName) (\(rawValue))"
    }
}

/// Per-preview settings chosen before the paywall opens. Kept for the lifetime of the process so a
/// tester who is iterating on one paywall does not re-pick the same options on every launch.
struct HeliumPreviewConfiguration: Equatable {
    var purchaseMode: HeliumPreviewPurchaseMode = .simulated
    var showCaliforniaConsentModal: Bool = false
    var traits: [HeliumPreviewKeyValue] = []
    var userAttributes: [HeliumPreviewKeyValue] = []
    var language: HeliumPreviewLanguage = .device

    var traitsSummary: String { HeliumPreviewConfiguration.summarize(traits, noun: "override") }
    var userAttributesSummary: String { HeliumPreviewConfiguration.summarize(userAttributes, noun: "attribute") }

    private static func summarize(_ entries: [HeliumPreviewKeyValue], noun: String) -> String {
        let count = entries.filter(\.isComplete).count
        switch count {
        case 0: return "None"
        case 1: return "1 \(noun)"
        default: return "\(count) \(noun)s"
        }
    }

    static var lastUsed = HeliumPreviewConfiguration()
}

/// What the configuration sheet is being opened for, so the sheet can name it and the panel knows
/// what to launch once the tester confirms.
struct HeliumPreviewConfigurationRequest: Identifiable {
    enum Target {
        case version(HeliumPaywallPreviewVersion, paywall: HeliumPaywallPreviewEntry)
        case fallback
    }

    let target: Target

    var id: String {
        switch target {
        case .version(let version, _): return version.id
        case .fallback: return "fallback"
        }
    }

    var paywallName: String {
        switch target {
        case .version(_, let paywall): return paywall.paywallName
        case .fallback: return "Default Fallback Paywall"
        }
    }

    var versionLabel: String? {
        switch target {
        case .version(let version, _): return version.displayLabel
        case .fallback: return nil
        }
    }

    var isWebPaywall: Bool {
        switch target {
        case .version(_, let paywall): return paywall.isWebPaywall
        case .fallback: return false
        }
    }
}
