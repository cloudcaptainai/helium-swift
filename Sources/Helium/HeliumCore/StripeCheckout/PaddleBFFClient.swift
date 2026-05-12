import Foundation

public enum PaddleBFFError: LocalizedError {
    case requestFailed(statusCode: Int, rawBody: String)

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode, let rawBody):
            return "Paddle BFF request failed (\(statusCode)): \(rawBody)"
        }
    }
}

public struct PaddleTransactionCheckoutResult {
    public let rawBody: Data
    public let checkoutId: String
    public let transactionId: String
    public let generatedAt: Date
}

final class PaddleBFFClient {

    private static let prodSourcePageOrigin = "https://bundles.clickthrough.to"
    private static let sandboxSourcePageOrigin = "https://bundles-staging.clickthrough.to"

    private static let prodCheckoutBaseURL = "https://checkout-service.paddle.com"
    private static let sandboxCheckoutBaseURL = "https://sandbox-checkout-service.paddle.com"

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func createTransactionCheckout(
        transactionId: String,
        paddleClientToken: String,
        iosBundleId: String?
    ) async throws -> PaddleTransactionCheckoutResult {
        let baseURL = paddleCheckoutBaseURL(for: paddleClientToken)
        let sourcePage = paddleSourcePage(for: paddleClientToken, iosBundleId: iosBundleId)

        guard let url = URL(string: baseURL + "/transaction-checkout") else {
            throw PaddleBFFError.requestFailed(statusCode: 0, rawBody: "Failed to construct URL from \(baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(paddleClientToken, forHTTPHeaderField: "Paddle-Clienttoken")

        let body: [String: Any] = [
            "data": [
                "settings": [
                    "theme": "light",
                    "locale": "en",
                    "display_mode": "inline",
                    "variant": "express",
                    "source_page": sourcePage,
                    "referrer": sourcePage,
                ],
                "transaction_id": transactionId,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard 200..<300 ~= statusCode else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw PaddleBFFError.requestFailed(statusCode: statusCode, rawBody: raw)
        }

        let envelope = try JSONDecoder().decode(BFFResponseEnvelope.self, from: data)
        return PaddleTransactionCheckoutResult(
            rawBody: data,
            checkoutId: envelope.data.id,
            transactionId: envelope.data.transactionId,
            generatedAt: Date()
        )
    }

    // MARK: - URL/source-page helpers

    private func paddleCheckoutBaseURL(for clientToken: String) -> String {
        return clientToken.hasPrefix("test_")
            ? Self.sandboxCheckoutBaseURL
            : Self.prodCheckoutBaseURL
    }

    private func paddleSourcePage(for clientToken: String, iosBundleId: String?) -> String {
        let origin = clientToken.hasPrefix("test_")
            ? Self.sandboxSourcePageOrigin
            : Self.prodSourcePageOrigin
        guard let trimmed = iosBundleId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return origin
        }
        guard var components = URLComponents(string: origin) else {
            return origin
        }
        // URLQueryItem (not addingPercentEncoding(.urlQueryAllowed)) —
        // the "allowed" set leaves ?&=+ unescaped, which would break
        // Paddle's source_page allow-list validation for odd bundle ids.
        components.queryItems = [
            URLQueryItem(name: "helium_ios_bundle_id", value: trimmed)
        ]
        return components.string ?? origin
    }

    // MARK: - Internal decode envelope

    private struct BFFResponseEnvelope: Decodable {
        let data: PaddleData

        struct PaddleData: Decodable {
            let id: String
            let transactionId: String

            enum CodingKeys: String, CodingKey {
                case id
                case transactionId = "transaction_id"
            }
        }
    }
}
