import Foundation

/// Networking client for Stripe-related API calls.
public class HeliumStripeAPIClient {

    public static let shared = HeliumStripeAPIClient()
    private init() {}

    /// The resolved base URL.
    public var heliumBaseURL: String { HeliumAPIEndpoint.baseURL }

    // MARK: - Networking

    public func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: heliumBaseURL + path) else {
            throw HeliumStripeAPIError.invalidEndpoint(path: path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let http = response as? HTTPURLResponse
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw HeliumStripeAPIError.serverError(statusCode: http?.statusCode ?? 0, message: message)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Request Body Builder

    public func baseRequestBody(productId: String? = nil) throws -> [String: Any] {
        guard let apiKey = Helium.lastApiKeyUsed else {
            throw HeliumStripeAPIError.notInitialized
        }
        var body: [String: Any] = [
            "apiKey": apiKey,
            "userId": Helium.identify.userId ?? HeliumIdentityManager.shared.getHeliumPersistentId(),
            "rcUserId": Helium.identify.revenueCatAppUserId ?? "",
            "stripeCustomerId": HeliumIdentityManager.shared.getStripeCustomerId() ?? "",
            "heliumPersistentId": HeliumIdentityManager.shared.getHeliumPersistentId(),
            "appTransactionId": HeliumIdentityManager.shared.getAppTransactionID() ?? ""
        ]
        if let productId {
            body["productPriceId"] = productId
        }
        return body
    }
}
