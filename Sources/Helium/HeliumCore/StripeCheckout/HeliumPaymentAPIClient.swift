import Foundation

/// Networking client for payment-related API calls (Stripe, Paddle, etc.).
public class HeliumPaymentAPIClient {

    public static let shared = HeliumPaymentAPIClient()

    private let urlSession: URLSession

    private init() {
        self.urlSession = .shared
    }

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

    // MARK: - Paddle Pre-Fetch

    /// Throws `PaddlePrefetchError.alreadyEntitled` on a 409 with a
    /// recognized code; other non-2xx responses throw
    /// `HeliumPaymentAPIError.serverError`. `priceId` is the bare
    /// `pri_xxx` form.
    func createPaddleTransactionForPaywall(
        priceId: String,
        discountId: String? = nil
    ) async throws -> PaddleCreateTransactionForPaywallResponse {
        var body = try baseRequestBody(provider: .paddle)
        body["priceId"] = priceId
        if let orgId = HeliumFetchedConfigManager.shared.getOrganizationID(), !orgId.isEmpty {
            body["orgId"] = orgId
        }
        // Forward the creator-configured discount id when present; omit it
        // entirely rather than sending "". The backend decides whether to
        // apply it based on the customer's eligibility.
        if let discountId, !discountId.isEmpty {
            body["discountId"] = discountId
        }

        let request = try makePostRequest(path: "paddle/create-transaction-for-paywall", body: body)

        let (data, response) = try await urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if 200..<300 ~= statusCode {
            return try JSONDecoder().decode(PaddleCreateTransactionForPaywallResponse.self, from: data)
        }

        if statusCode == 409,
           let envelope = try? JSONDecoder().decode(PaymentAPIErrorEnvelope.self, from: data),
           let code = envelope.error.code,
           PaddleErrorCodes.isPrefetchAlreadyEntitled(code) {
            let detail = envelope.error.detail
                ?? PaddleErrorCodes.defaultMessage(for: code)
            let existingSubscriptionId = HeliumPaymentAPIClient.extractExistingSubscriptionId(from: data)
            throw PaddlePrefetchError.alreadyEntitled(
                code: code,
                message: detail,
                existingSubscriptionId: existingSubscriptionId
            )
        }
        throw genericServerError(statusCode: statusCode, body: data)
    }

    /// Best-effort extraction of the existing subscription id from a 409 body.
    /// Returns nil when no recognized path yields a non-empty string.
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
