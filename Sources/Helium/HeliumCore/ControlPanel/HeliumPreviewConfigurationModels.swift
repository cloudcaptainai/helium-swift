import Foundation

/// How a preview handles the app2web checkout it kicks out to.
enum HeliumPreviewPurchaseMode: String, CaseIterable, Identifiable {
    case simulated
    case sandbox
    case real

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simulated: return "Simulated purchase"
        case .sandbox: return "Sandbox purchase"
        case .real: return "Real purchase"
        }
    }

    var detail: String {
        switch self {
        case .simulated:
            return "Looks like the normal purchase flow but no transaction occurs and no entitlement granted."
        case .sandbox:
            return "Checks out on your Paddle sandbox account. Use a Paddle test card; no real charge."
        case .real:
            return "Checks out on your production account. Your card is charged and entitlement granted."
        }
    }

    var systemImageName: String {
        switch self {
        case .simulated: return "sparkles"
        case .sandbox: return "testtube.2"
        case .real: return "creditcard"
        }
    }

    /// Sandbox is a Paddle account, so a Stripe checkout in sandbox mode stays simulated
    /// rather than charging a real card.
    func isSimulated(for processor: HeliumPaymentProcessor) -> Bool {
        switch self {
        case .simulated: return true
        case .sandbox: return processor != .paddle
        case .real: return false
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

    /// California eligibility from `/preview-paywalls`: the device may purchase for
    /// real, but only through the consent modal, so the toggle is forced on.
    @Published var forcePaddleCaConsentModal = false

    @Published private var chosenShowCaliforniaConsentModal = false

    var showCaliforniaConsentModal: Bool {
        get { forcePaddleCaConsentModal || chosenShowCaliforniaConsentModal }
        set { chosenShowCaliforniaConsentModal = newValue }
    }

    /// Whether a `/preview-paywalls` response sent without a Paddle account override carried a
    /// sandbox (`test_`) client token, so the org has a sandbox account this build routes to.
    @Published var paddleSandboxAvailable = false

    @Published private var chosenPurchaseMode: HeliumPreviewPurchaseMode?

    /// A response fetched with the production override carries the live token whether or not a
    /// sandbox account exists, so only an automatic fetch can tell.
    func updatePaddleSandboxAvailability(clientToken: String?, requestedProductionAccount: Bool) {
        guard !requestedProductionAccount else { return }
        paddleSandboxAvailable = clientToken?.hasPrefix("test_") == true
    }

    var purchaseModes: [HeliumPreviewPurchaseMode] {
        HeliumPreviewPurchaseMode.allCases.filter { $0 != .sandbox || paddleSandboxAvailable }
    }

    /// The tester's pick, before the region check. Defaults to sandbox when it exists so a test
    /// build never charges a card unless the tester asks for it.
    private var selectedPurchaseMode: HeliumPreviewPurchaseMode {
        switch chosenPurchaseMode {
        case .sandbox? where !paddleSandboxAvailable: return .real
        case let mode?: return mode
        case nil: return paddleSandboxAvailable ? .sandbox : .real
        }
    }

    /// Sandbox checkouts are not region-gated, so only a real purchase is forced to simulated.
    var purchaseMode: HeliumPreviewPurchaseMode {
        get {
            let mode = selectedPurchaseMode
            if mode == .real && forceExternalCheckoutSimulation { return .simulated }
            return mode
        }
        set { chosenPurchaseMode = newValue }
    }

    /// A real purchase on a build that would otherwise route to the sandbox account asks for the
    /// production account. Keyed off the pick rather than `purchaseMode`, so a region check that
    /// forces simulated does not flip the account back and forth between fetches.
    var paddleAccountOverride: HeliumPaddleAccountOverride {
        paddleSandboxAvailable && selectedPurchaseMode == .real ? .production : .automatic
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

/// App2web checkout bundles built before the simulated-purchase flow ignore the simulated flag
/// and would charge a real card in a preview, so previews are gated on the bundle's build time
/// (stamped in its filename) being at or after this cutoff, in epoch ms.
enum HeliumPreviewBundleFreshness {
    static let app2webCutoffMs: Int64 = 1787881704000

    static func staleBundleMessage(webPaywallName: String?) -> String {
        let target = webPaywallName.map { "The linked web paywall \"\($0)\"" } ?? "The web paywall linked to this paywall"
        return "\(target) needs an update. Re-save and publish it in your Helium dashboard, then reload."
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

    /// Reads the build time from the checkout bundle's `bundle_<ms>.html` filename; a missing or
    /// unparseable stamp fails closed (treated as too old).
    var isApp2webBundleFresh: Bool {
        guard let webPaywallBundleUrl,
              let bundleId = HeliumAssetManager.shared.getBundleIdFromURL(webPaywallBundleUrl),
              let builtAtMs = Int64(bundleId) else {
            return false
        }
        return builtAtMs >= HeliumPreviewBundleFreshness.app2webCutoffMs
    }
}

extension HeliumPaywallPreviewEntry {
    var isApp2webCapable: Bool {
        versions.contains { $0.isApp2webCapable }
    }
}
