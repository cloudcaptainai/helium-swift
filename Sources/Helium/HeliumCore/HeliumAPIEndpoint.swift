import Foundation

/// Single source of truth for the Helium API base URL.
enum HeliumAPIEndpoint {
    static let defaultBaseURL = "https://api-v2.tryhelium.com/"

    /// The resolved base URL, respecting `Helium.config.customAPIEndpoint`.
    static var baseURL: String {
        guard let custom = Helium.config.customAPIEndpoint,
              let url = URL(string: custom),
              let scheme = url.scheme,
              let host = url.host else {
            return defaultBaseURL
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)/"
    }
}
