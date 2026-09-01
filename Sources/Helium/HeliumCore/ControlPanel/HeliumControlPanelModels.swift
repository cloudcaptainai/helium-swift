import Foundation

struct HeliumControlPanelResponse: Codable {
    let productIds: [String]
    let paywalls: [HeliumPaywallPreviewEntry]
    let stripeProducts: [String: ServerProductPrice]?
    let paddleProducts: [String: ServerProductPrice]?
    let paddleClientToken: String?
    /// Whether this device is not cleared for a real external checkout, so previews
    /// should default to a simulated purchase. Optional: readers treat absent as true.
    let forceExternalCheckoutSimulation: Bool?
    /// A verified US-California device: real checkout is allowed, but showing the CA
    /// consent modal is a hard precondition for a Paddle purchase. Absent reads false.
    let forcePaddleCaConsentModal: Bool?
}

struct HeliumPaywallPreviewEntry: Codable, Identifiable {
    let paywallUuid: String
    let paywallName: String
    let paywallTemplateName: String?
    let paywallId: Int?
    let isWeb: Bool?
    let versions: [HeliumPaywallPreviewVersion]
    let secondTry: HeliumPaywallPreviewSecondTry?
    var id: String { paywallUuid }

    /// Web paywalls render in a browser, not in-app; previews open them there.
    var isWebPaywall: Bool {
        if let isWeb { return isWeb }
        return versions.contains { version in
            guard let bundleUrl = version.bundleUrl, let host = URL(string: bundleUrl)?.host else {
                return false
            }
            return Self.webPaywallBundleHosts.contains(host)
        }
    }

    private static let webPaywallBundleHosts: Set<String> = [
        "bundles.clickthrough.to",
        "bundles-staging.clickthrough.to",
    ]
}

/// The resolved second try paywall served with a preview entry. Paywall-level, not per-version:
/// every version of the entry shares the same second try link.
struct HeliumPaywallPreviewSecondTry: Codable {
    let paywallUuid: String
    let paywallName: String
    let paywallTemplateName: String?
    let paywallId: Int?
    /// "published" when the second try paywall is live; "draft" when it has never been
    /// published, in which case real users do not see it until the paywall is published.
    /// Optional so a malformed entry can't fail decoding the whole preview list.
    let versionStatus: String?
    let bundleUrl: String?
    let productIds: [String]?
    let stripeProductIds: [String]?
    let paddleProductIds: [String]?
    let shouldEnableScroll: Bool?
}

struct HeliumPaywallPreviewVersion: Codable, Identifiable {
    let versionId: String
    let versionStatus: String
    let versionNumber: Int?
    let bundleUrl: String?
    let previewUrl: String?
    let productIds: [String]?
    let stripeProductIds: [String]?
    let paddleProductIds: [String]?
    let webPaddleProductIds: [String]?
    let webStripeProductIds: [String]?
    let webPaywallBundleUrl: String?
    let shouldEnableScroll: Bool?
    let lastSavedAt: String?
    var id: String { versionId }

    var formattedSavedDate: String {
        guard let lastSavedAt else { return "—" }
        return formatDateForDisplay(lastSavedAt)
    }

    var displayLabel: String {
        if let versionNumber {
            return "v\(versionNumber) (\(versionStatus))"
        }
        return versionStatus
    }
}

enum HeliumControlPanelState {
    case loading
    case loaded(HeliumControlPanelResponse)
    case error(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// What the control panel is currently doing to launch a preview. Launching mutates the shared
/// preview-trigger config and hands presentation to a deferred main-actor job, so every preview
/// tap target stays disabled from the tap until the preview closes or reports that it could not
/// be shown. Releasing while a presentation is pending would let a second tap rewrite the
/// preview-trigger config out from under it; releasing while a preview is on screen would let a
/// second tap stack another preview over it.
enum HeliumControlPanelActivity: Equatable {
    case idle
    /// A paywall version's bundle is downloading; the id drives that version row's spinner.
    case loadingVersion(id: String)
    /// A preview is in the presenter's hands: presentation pending, on screen, or closing.
    case presentingPaywall
}
