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
        let request = try makePostRequest(path: path, body: body)
        let (data, response) = try await urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard 200..<300 ~= statusCode else {
            throw genericServerError(statusCode: statusCode, body: data)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Request / response shared helpers

    /// Builds a JSON-bodied POST request to `heliumBaseURL + path`. Single
    /// source of truth for the headers and method-setup logic so future
    /// changes (e.g. add a User-Agent) land in one place.
    private func makePostRequest(path: String, body: [String: Any]) throws -> URLRequest {
        guard let url = URL(string: heliumBaseURL + path) else {
            throw HeliumPaymentAPIError.invalidEndpoint(path: path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Parses a non-2xx response body into the generic
    /// `HeliumPaymentAPIError.serverError(statusCode:message:)` shape. Tries
    /// the structured `PaymentAPIErrorEnvelope` first; defaults to the raw
    /// body text if the envelope doesn't decode. Used by `post()` and as the
    /// non-409-duplicate default path in `createPaddleTransactionForPaywall`.
    private func genericServerError(statusCode: Int, body: Data) -> HeliumPaymentAPIError {
        if let envelope = try? JSONDecoder().decode(PaymentAPIErrorEnvelope.self, from: body),
           case let parts = [envelope.error.code, envelope.error.type, envelope.error.detail]
               .compactMap({ $0 })
               .filter({ !$0.isEmpty }),
           !parts.isEmpty {
            var message = parts.joined(separator: ": ")
            if let requestId = envelope.meta?.requestId, !requestId.isEmpty {
                message += " (requestId: \(requestId))"
            }
            return HeliumPaymentAPIError.serverError(statusCode: statusCode, message: message)
        }
        let raw = String(data: body, encoding: .utf8) ?? "Unknown error"
        return HeliumPaymentAPIError.serverError(statusCode: statusCode, message: raw)
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

    /// Pre-creates a Paddle transaction during paywall display so the bundle
    /// in Safari can skip its own bandit round-trip on Subscribe.
    ///
    /// Throws `PaddlePrefetchError.alreadyEntitled` on a 409 carrying a
    /// recognized code (see `PaddleErrorCodes`); all other failures throw
    /// `HeliumPaymentAPIError.serverError` or the underlying transport
    /// error. The 409 path is split out so callers pattern-match on
    /// `code` instead of string-matching the message.
    ///
    /// `priceId` must be the bare `pri_xxx` form — bandit validates the
    /// field name and rejects the `product:price` composite that
    /// `baseRequestBody(productId:)` would produce.
    func createPaddleTransactionForPaywall(
        priceId: String
    ) async throws -> PaddleCreateTransactionForPaywallResponse {
        // baseRequestBody without `productId:` so we don't get the Stripe-
        // shaped `productPriceId` field; we add the Paddle-shaped `priceId`
        // explicitly below.
        var body = try baseRequestBody(provider: .paddle)
        body["priceId"] = priceId
        if let orgId = HeliumFetchedConfigManager.shared.getOrganizationID(), !orgId.isEmpty {
            body["orgId"] = orgId
        }

        let request = try makePostRequest(path: "paddle/create-transaction-for-paywall", body: body)

        let (data, response) = try await urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if 200..<300 ~= statusCode {
            return try JSONDecoder().decode(PaddleCreateTransactionForPaywallResponse.self, from: data)
        }

        // 409 with a recognized alreadyEntitled-class code is surfaced
        // as a typed error so the prefetch coordinator can pattern-match
        // structurally. The allow-list lives in `PaddleErrorCodes` —
        // adding a new code is a deliberate decision that should land
        // on both the SDK and the bundle (`routePaddle409`) together.
        //
        // The SDK doesn't differentiate UX semantics here — it just
        // surfaces the code verbatim. Downstream
        // (PaddleCheckoutPrefetchCoordinator.tappedShortCircuit and the
        // bundle's decidePaddleSubscribeAction) decide success vs
        // failure routing per `PaddleErrorCodes.isRestorable` and
        // `routePaddle409` respectively.
        if statusCode == 409,
           let envelope = try? JSONDecoder().decode(PaymentAPIErrorEnvelope.self, from: data),
           let code = envelope.error.code,
           PaddleErrorCodes.isPrefetchAlreadyEntitled(code) {
            let detail = envelope.error.detail
                ?? PaddleErrorCodes.defaultMessage(for: code)
            // Best-effort sub-id extraction. Mirrors the bundler's
            // `parsePaddle409` 5-path lookup so the SDK and bundle agree on
            // where existingSubscriptionId can live in a 409 body. Threaded
            // into ctx.paddleAlreadyEntitled so the bundle's
            // `helium_purchase_already_entitled` Jitsu fire can include it
            // as `canonicalJoinTransactionId`.
            let existingSubscriptionId = HeliumPaymentAPIClient.extractExistingSubscriptionId(from: data)
            throw PaddlePrefetchError.alreadyEntitled(
                code: code,
                message: detail,
                existingSubscriptionId: existingSubscriptionId
            )
        }
        throw genericServerError(statusCode: statusCode, body: data)
    }

    /// Extracts the buyer's existing Paddle subscription id from a bandit
    /// 409 body. Mirrors `parsePaddle409` in
    /// `bundler-service/server/heliumStandalonePaddle.ts` — the same five
    /// paths, in order of specificity (first non-empty wins):
    ///   1. error.subscription_id        (Paddle's canonical snake_case)
    ///   2. error.subscriptionId         (camelCased by some transforms)
    ///   3. error.meta.subscription_id   (Paddle nests metadata sometimes)
    ///   4. subscription_id              (top-level; bandit may hoist it)
    ///   5. subscriptionId               (top-level camelCase)
    ///
    /// Returns nil when none of the paths produce a non-empty string.
    /// Defensive against malformed bodies — never throws.
    static func extractExistingSubscriptionId(from data: Data) -> String? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let errorObj = parsed["error"] as? [String: Any] ?? [:]
        let candidates: [Any?] = [
            errorObj["subscription_id"],
            errorObj["subscriptionId"],
            (errorObj["meta"] as? [String: Any])?["subscription_id"],
            parsed["subscription_id"],
            parsed["subscriptionId"],
        ]
        for candidate in candidates {
            if let s = candidate as? String, !s.isEmpty {
                return s
            }
        }
        return nil
    }
}

public typealias HeliumStripeAPIClient = HeliumPaymentAPIClient
