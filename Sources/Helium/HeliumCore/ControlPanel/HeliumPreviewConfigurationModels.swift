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
            return "Looks like the normal purchase flow but no transaction occurs and no entitlement granted."
        case .real:
            return "Complete real purchases. Your card is charged and entitlement granted."
        }
    }

    var systemImageName: String {
        switch self {
        case .simulated: return "testtube.2"
        case .real: return "creditcard"
        }
    }

    /// Real external checkout is only cleared for US buyers today.
    var isUSOnly: Bool { self == .real }
}

/// App2web options a preview run applies when it kicks out to the external checkout.
struct HeliumPreviewConfiguration: Equatable {
    var purchaseMode: HeliumPreviewPurchaseMode = .simulated
    var showCaliforniaConsentModal: Bool = false
}

/// Session-scoped app2web preview settings, applied to every preview launch so a tester
/// configures once instead of re-picking on each open. In-memory for the process lifetime.
final class HeliumPreviewConfigurationStore: ObservableObject {
    static let shared = HeliumPreviewConfigurationStore()
    private init() {}

    /// When true, an app2web preview shows the configuration screen before presenting.
    @Published var configureBeforeEachPreview = false

    /// Purchase eligibility from `/preview-paywalls`. Starts true so an absent or
    /// unparsed signal keeps previews on the simulated path.
    @Published var forceExternalCheckoutSimulation = true

    @Published var showCaliforniaConsentModal = false

    @Published private var chosenPurchaseMode: HeliumPreviewPurchaseMode?

    /// Defaults to the mode the device is eligible for until the tester picks one.
    var purchaseMode: HeliumPreviewPurchaseMode {
        get {
            if forceExternalCheckoutSimulation { return .simulated }
            return chosenPurchaseMode ?? .real
        }
        set { chosenPurchaseMode = newValue }
    }

    var configuration: HeliumPreviewConfiguration {
        get {
            HeliumPreviewConfiguration(
                purchaseMode: purchaseMode,
                showCaliforniaConsentModal: showCaliforniaConsentModal
            )
        }
        set {
            purchaseMode = newValue.purchaseMode
            showCaliforniaConsentModal = newValue.showCaliforniaConsentModal
        }
    }

}

/// What the configuration screen is being opened for: editing the session settings from the
/// previews list, or confirming them ahead of one paywall launch.
struct HeliumPreviewConfigurationRequest: Identifiable {
    enum Target {
        case version(HeliumPaywallPreviewVersion, paywall: HeliumPaywallPreviewEntry)
        case settings
    }

    let target: Target

    var id: String {
        switch target {
        case .version(let version, _): return version.id
        case .settings: return "settings"
        }
    }

    var isSettings: Bool {
        if case .settings = target { return true }
        return false
    }

    var title: String {
        switch target {
        case .version(_, let paywall): return paywall.paywallName
        case .settings: return "App2Web Previews"
        }
    }

    var versionLabel: String? {
        switch target {
        case .version(let version, _): return version.displayLabel
        case .settings: return nil
        }
    }

    /// The CA consent toggle only exists on Paddle checkouts, so it is hidden for a
    /// Stripe-only paywall. The session settings screen always shows it.
    var showsCompliance: Bool {
        switch target {
        case .version(let version, _): return version.hasApp2webPaddle
        case .settings: return true
        }
    }
}

extension HeliumPaywallPreviewVersion {
    var hasApp2webPaddle: Bool {
        webPaywallBundleUrl != nil && !(webPaddleProductIds ?? []).isEmpty
    }

    var hasApp2webStripe: Bool {
        webPaywallBundleUrl != nil && !(webStripeProductIds ?? []).isEmpty
    }

    var isApp2webCapable: Bool { hasApp2webPaddle || hasApp2webStripe }
}

extension HeliumPaywallPreviewEntry {
    var isApp2webCapable: Bool {
        versions.contains { $0.isApp2webCapable }
    }
}
