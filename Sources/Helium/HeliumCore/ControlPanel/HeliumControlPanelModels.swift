import Foundation

struct HeliumControlPanelResponse: Codable {
    let productIds: [String]
    let paywalls: [HeliumPaywallPreview]
}

struct HeliumPaywallPreview: Codable, Identifiable {
    let bundleUrl: String
    let paywallUuid: String
    let paywallName: String
    let eventPreviewUrl: String?
    let productIds: [String]
    let versionNumber: Int
    let versionId: String
    let lastPublishedAt: String
    var id: String { paywallUuid }

    var formattedPublishedDate: String {
        formatDateForDisplay(lastPublishedAt)
    }
}

enum HeliumControlPanelState {
    case loading
    case loaded(HeliumControlPanelResponse)
    case error(String)
}
