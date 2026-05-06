import Foundation

/// Errors specific to Paddle's checkout-service BFF (`*-checkout-service.paddle.com`).
/// Distinct from `HeliumPaymentAPIError` because the BFF is a third-party
/// service with its own response shape — flattening it through Helium's
/// generic error type would lose the structured info Paddle returns
/// (errors[].code, errors[].detail, etc.).
public enum PaddleBFFError: LocalizedError {
    /// Non-2xx response from Paddle's BFF. Body is the raw response so
    /// callers (and tests) can inspect Paddle-specific error shapes.
    case requestFailed(statusCode: Int, rawBody: String)

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode, let rawBody):
            return "Paddle BFF request failed (\(statusCode)): \(rawBody)"
        }
    }
}

/// Successful response from Paddle's `POST /transaction-checkout`.
///
/// We deliberately keep this struct tiny (just the fields the SDK itself
/// needs for cache keying / sanity checks) and preserve the full response
/// body as raw `Data` for forwarding. Paddle's response is rich (items,
/// totals, methods_available, ip_geo_*, customer, ...) and the bundle in
/// Safari already has a complete decoder for it. Re-decoding everything on
/// the SDK side would be duplicate work and a maintenance liability —
/// every new Paddle field would need a Codable mirror here.
///
/// Stage 6 of the prefetch path encodes `rawBody` into the bundle URL's
/// `ctx.paddleBootstrap.paddleCheckoutResponseBody`, where the bundle's
/// existing decoder consumes it.
public struct PaddleTransactionCheckoutResult {
    /// Full JSON response body from Paddle. Forwarded as-is to the bundle.
    public let rawBody: Data

    /// Paddle's checkout session id (`che_xxx`). Used by the SDK for
    /// logging and cache sanity-checks; the bundle reads it from rawBody.
    public let checkoutId: String

    /// Echo of `transaction_id` from the request, surfaced as a sanity
    /// check that the BFF saw and persisted the bandit's transaction.
    public let transactionId: String
}

/// Client for Paddle's checkout-service BFF (`*-checkout-service.paddle.com`).
///
/// This is the second half of the SDK pre-fetch chain (HEL-5326). The
/// bundler runs the equivalent flow at runtime; the SDK pre-runs it during
/// in-app paywall presentation so the bundle in Safari can skip the
/// round-trip entirely.
///
/// URL selection mirrors `server/builder.js` (line ~1056): a `test_*`
/// client token routes to sandbox, anything else routes to prod. This
/// keeps env separation rooted in the token itself — no separate config
/// flag for the SDK to get out of sync.
final class PaddleBFFClient {

    /// Bundler's hard-coded fallback origin (server/heliumStandalonePaddle.ts).
    /// We use the same per-environment values so source_page survives Paddle's
    /// strict validation against the global allow-list (paddle has approved
    /// both `bundles.clickthrough.to` and `bundles-staging.clickthrough.to`).
    private static let prodSourcePageOrigin = "https://bundles.clickthrough.to"
    private static let sandboxSourcePageOrigin = "https://bundles-staging.clickthrough.to"

    private static let prodCheckoutBaseURL = "https://checkout-service.paddle.com"
    private static let sandboxCheckoutBaseURL = "https://sandbox-checkout-service.paddle.com"

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Calls `POST {paddleCheckoutBase}/transaction-checkout` with the
    /// transaction id from a successful bandit
    /// `/paddle/create-transaction-for-paywall` response. Returns the BFF
    /// response body (raw + minimal decoded fields) on 2xx; throws
    /// `PaddleBFFError.requestFailed` otherwise.
    ///
    /// `iosBundleId` becomes a query param on `source_page` so Paddle can
    /// attribute transactions per app for AUP enforcement (matches the
    /// bundler's `buildPaddleSourcePage` helper).
    func createTransactionCheckout(
        transactionId: String,
        paddleClientToken: String,
        iosBundleId: String?
    ) async throws -> PaddleTransactionCheckoutResult {
        let baseURL = paddleCheckoutBaseURL(for: paddleClientToken)
        let sourcePage = paddleSourcePage(for: paddleClientToken, iosBundleId: iosBundleId)

        guard let url = URL(string: baseURL + "/transaction-checkout") else {
            // Should be unreachable given the constants are static
            // strings, but typed errors are cheap and keep the API total.
            throw PaddleBFFError.requestFailed(statusCode: 0, rawBody: "Failed to construct URL from \(baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(paddleClientToken, forHTTPHeaderField: "Paddle-Clienttoken")

        // Body shape matches bundler's runtime call exactly
        // (server/heliumStandalonePaddle.ts:~1497). Variant + display_mode +
        // theme + locale are required by Paddle for the express checkout
        // flow; source_page is strict-validated.
        let body: [String: Any] = [
            "data": [
                "settings": [
                    "theme": "light",
                    "locale": "en",
                    "display_mode": "inline",
                    "variant": "express",
                    "source_page": sourcePage,
                    // Paddle treats `referrer` as informational (not strict-
                    // validated); send the same value as source_page so
                    // analytics show consistent attribution.
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

        // Decode just the two fields we need internally; preserve the
        // raw body for forwarding to the bundle.
        let envelope = try JSONDecoder().decode(BFFResponseEnvelope.self, from: data)
        return PaddleTransactionCheckoutResult(
            rawBody: data,
            checkoutId: envelope.data.id,
            transactionId: envelope.data.transactionId
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
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return "\(origin)?helium_ios_bundle_id=\(encoded)"
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
