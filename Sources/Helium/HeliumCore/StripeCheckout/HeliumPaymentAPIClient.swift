import Foundation

/// Networking client for payment-related API calls (Stripe, Paddle, etc.).
public class HeliumPaymentAPIClient {

    public static let shared = HeliumPaymentAPIClient()

    /// Underlying URLSession for outgoing requests. Defaulted to `.shared`
    /// for production; tests construct an instance via `init(urlSession:)`
    /// with a session that has MockURLProtocol registered.
    private let urlSession: URLSession

    private init() {
        self.urlSession = .shared
    }

    /// Internal initializer for tests. Lets tests drive the client with a
    /// URLSession backed by MockURLProtocol so requests are intercepted
    /// without touching the real network. Production callers always go
    /// through `.shared`, which uses `URLSession.shared`.
    internal init(urlSession: URLSession) {
        self.urlSession = urlSession
    }

    public var heliumBaseURL: String { HeliumAPIEndpoint.baseURL }

    // MARK: - Networking

    public func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: heliumBaseURL + path) else {
            throw HeliumPaymentAPIError.invalidEndpoint(path: path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let rawBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            let message: String
            if let envelope = try? JSONDecoder().decode(PaymentAPIErrorEnvelope.self, from: data),
               case let parts = [envelope.error.code, envelope.error.type, envelope.error.detail]
                   .compactMap({ $0 })
                   .filter({ !$0.isEmpty }),
               !parts.isEmpty {
                let core = parts.joined(separator: ": ")
                if let requestId = envelope.meta?.requestId, !requestId.isEmpty {
                    message = "\(core) (requestId: \(requestId))"
                } else {
                    message = core
                }
            } else {
                message = rawBody
            }
            throw HeliumPaymentAPIError.serverError(statusCode: statusCode, message: message)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Request Body Builder

    func baseRequestBody(provider: PaymentProviderConfig, productId: String? = nil) throws -> [String: Any] {
        guard let apiKey = Helium.lastApiKeyUsed else {
            throw HeliumPaymentAPIError.notInitialized
        }
        var body: [String: Any] = [
            "apiKey": apiKey,
            "heliumPersistentId": HeliumIdentityManager.shared.getHeliumPersistentId()
        ]
        if let userId = Helium.identify.userId {
            body["userId"] = userId
        }
        if let rcUserId = Helium.identify.revenueCatAppUserId {
            body["rcUserId"] = rcUserId
        }
        if let appTransactionId = HeliumIdentityManager.shared.getAppTransactionID() {
            body["appTransactionId"] = appTransactionId
        }
        if let customerId = provider.getCustomerId(), !customerId.isEmpty {
            body[provider.customerIdBodyKey] = customerId
        }
        if let productId {
            body["productPriceId"] = productId
        }
        return body
    }

    /// Convenience that defaults to Stripe for backward compatibility.
    public func baseRequestBody(productId: String? = nil) throws -> [String: Any] {
        try baseRequestBody(provider: .stripe, productId: productId)
    }

    // MARK: - Paddle Pre-Fetch (HEL-5326)

    /// Calls bandit's `POST /paddle/create-transaction-for-paywall` to
    /// pre-create a Paddle transaction during paywall presentation. Used by
    /// the SDK pre-fetch path (HEL-5326): the bundle in Safari then skips
    /// its own bandit round-trip and goes straight to opening the Apple Pay
    /// sheet from cached data.
    ///
    /// Error semantics:
    ///   * 200 → returns the decoded response.
    ///   * 409 with `error.code == "duplicate_subscription"` → throws
    ///     `PaddlePrefetchError.alreadyEntitled(code, message)`. Callers
    ///     translate this into a `preCheckResolved` outcome (don't open
    ///     browser, fire `purchase_already_entitled`).
    ///   * Anything else (other 4xx/5xx, transport errors, decode failures)
    ///     → `HeliumPaymentAPIError.serverError(statusCode, message)` or
    ///     the underlying transport error.
    ///
    /// Doesn't go through `post()` because we need to inspect the parsed
    /// error envelope's `code` field structurally — `post()` collapses code
    /// + type + detail into a single message string, which would force
    /// fragile string-matching on the caller side. Duplication here is
    /// scoped to one method and worth it for the type safety.
    func createPaddleTransactionForPaywall(
        priceId: String
    ) async throws -> PaddleCreateTransactionForPaywallResponse {
        let body = try baseRequestBody(provider: .paddle, productId: priceId)

        let path = "paddle/create-transaction-for-paywall"
        guard let url = URL(string: heliumBaseURL + path) else {
            throw HeliumPaymentAPIError.invalidEndpoint(path: path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if 200..<300 ~= statusCode {
            return try JSONDecoder().decode(PaddleCreateTransactionForPaywallResponse.self, from: data)
        }

        // Non-2xx: try to parse the structured error envelope. We branch on
        // 409 + duplicate_subscription specifically because the prefetch
        // coordinator translates that into a different control flow path
        // (preCheckResolved instead of opened-with-error).
        if let envelope = try? JSONDecoder().decode(PaymentAPIErrorEnvelope.self, from: data) {
            if statusCode == 409, envelope.error.code == "duplicate_subscription" {
                let detail = envelope.error.detail
                    ?? "You already have an active subscription for this product."
                throw PaddlePrefetchError.alreadyEntitled(code: "duplicate_subscription", message: detail)
            }
            // Generic structured error: surface in the same shape post()
            // uses so callers that already handle HeliumPaymentAPIError
            // don't need a second branch.
            let parts = [envelope.error.code, envelope.error.type, envelope.error.detail]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            var message = parts.joined(separator: ": ")
            if let requestId = envelope.meta?.requestId, !requestId.isEmpty {
                message += " (requestId: \(requestId))"
            }
            throw HeliumPaymentAPIError.serverError(statusCode: statusCode, message: message)
        }

        // Body wasn't envelope-shaped: surface raw text so the caller still
        // gets a debuggable error.
        let raw = String(data: data, encoding: .utf8) ?? "Unknown error"
        throw HeliumPaymentAPIError.serverError(statusCode: statusCode, message: raw)
    }
}

public typealias HeliumStripeAPIClient = HeliumPaymentAPIClient
