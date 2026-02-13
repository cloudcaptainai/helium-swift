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
    var id: String { paywallUuid }
}

enum HeliumControlPanelState {
    case loading
    case loaded(HeliumControlPanelResponse)
    case error(String)
}
