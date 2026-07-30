import Foundation

struct HeliumControlPanelResponse: Codable {
    let productIds: [String]
    let paywalls: [HeliumPaywallPreviewEntry]
}

struct HeliumPaywallPreviewEntry: Codable, Identifiable {
    let paywallUuid: String
    let paywallName: String
    let isWeb: Bool?
    let versions: [HeliumPaywallPreviewVersion]
    var id: String { paywallUuid }

    /// Web paywalls render in a browser, not in-app; previews open them there.
    var isWebPaywall: Bool { isWeb == true }
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
/// tap target must stay disabled from the tap until the presenter reports an outcome (opened or
/// not shown). Releasing sooner would let a second tap rewrite the preview-trigger config out
/// from under a presentation that has not resolved it yet.
enum HeliumControlPanelActivity: Equatable {
    case idle
    /// A paywall version's bundle is downloading; the id drives that version row's spinner.
    case loadingVersion(id: String)
    /// A preview has been handed to the presenter and no outcome has fired yet.
    case presentingPaywall
}
