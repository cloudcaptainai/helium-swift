import Foundation

struct HeliumControlPanelResponse: Codable {
    let productIds: [String]
    let stripeProductIds: [String]?
    let paywalls: [HeliumPaywallPreviewEntry]
}

struct HeliumPaywallPreviewEntry: Codable, Identifiable {
    let paywallUuid: String
    let paywallName: String
    let versions: [HeliumPaywallPreviewVersion]
    var id: String { paywallUuid }
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
