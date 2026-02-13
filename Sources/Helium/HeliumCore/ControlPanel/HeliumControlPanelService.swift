import Foundation

class HeliumControlPanelService {
    static let shared = HeliumControlPanelService()
    private init() {}

    private let endpoint = "https://api-v2.tryhelium.com/preview-paywalls"

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
