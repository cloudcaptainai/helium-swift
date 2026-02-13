import Foundation

class HeliumControlPanelService {
    static let shared = HeliumControlPanelService()
    private init() {}

    private let endpoint = "https://api-v2.tryhelium.com/preview-paywalls"

    /// Fetches a single bundle HTML from a URL for preview purposes.
    func fetchSingleBundle(bundleURL: String) async throws -> (bundleId: String, html: String) {
        guard HeliumFetchedConfigManager.shared.isValidURL(bundleURL) else {
            throw HeliumControlPanelError.badURL
        }

        guard let bundleId = HeliumAssetManager.shared.getBundleIdFromURL(bundleURL) else {
            throw HeliumControlPanelError.badURL
        }

        guard let url = URL(string: bundleURL) else {
            throw HeliumControlPanelError.badURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw HeliumControlPanelError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw HeliumControlPanelError.networkError(URLError(.badServerResponse))
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw HeliumControlPanelError.decodingError(URLError(.cannotDecodeContentData))
        }

        return (bundleId, html)
    }

    func fetchPreviewPaywalls() async throws -> HeliumControlPanelResponse {
        guard let apiKey = Helium.shared.controller?.apiKey else {
            throw HeliumControlPanelError.noApiKey
        }

        guard let url = URL(string: endpoint) else {
            throw HeliumControlPanelError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = ["apiKey": apiKey]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw HeliumControlPanelError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HeliumControlPanelError.networkError(URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data.prefix(200), encoding: .utf8)
            throw HeliumControlPanelError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        do {
            return try JSONDecoder().decode(HeliumControlPanelResponse.self, from: data)
        } catch {
            throw HeliumControlPanelError.decodingError(error)
        }
    }
}

enum HeliumControlPanelError: LocalizedError {
    case noApiKey
    case badURL
    case httpError(statusCode: Int, message: String?)
    case decodingError(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noApiKey:
            return "No API key available. Ensure Helium is initialized."
        case .badURL:
            return "Invalid endpoint URL."
        case .httpError(let statusCode, let message):
            return "HTTP \(statusCode): \(message ?? "Unknown error")"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
