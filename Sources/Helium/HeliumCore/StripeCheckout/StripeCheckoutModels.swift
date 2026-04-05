import Foundation

// MARK: - Checkout Result

public enum StripeCheckoutResult {
    case success(sessionId: String?)
    case cancelled
    case failed(Error)
}

// MARK: - URL Constants

enum StripeCheckoutRedirect {
    static func isSuccess(_ url: URL) -> Bool {
        guard let successUrl = Helium.config.stripeCheckoutSuccessURL,
              let configured = URL(string: successUrl) else { return false }
        return url.scheme == configured.scheme
            && url.host == configured.host
            && url.path == configured.path
    }

    static func isCancelled(_ url: URL) -> Bool {
        guard let cancelUrl = Helium.config.stripeCheckoutCancelURL,
              let configured = URL(string: cancelUrl) else { return false }
        return url.scheme == configured.scheme
            && url.host == configured.host
            && url.path == configured.path
    }
}

// MARK: - Pending Checkout Persistence

/// Persisted state for checkout sessions that survive app termination.
struct PendingCheckout: Codable {
    let productId: String
    let sessionId: String
    let triggerName: String
    let paywallName: String
    let paywallSessionId: String?
    let timestamp: Date

    var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > 24 * 60 * 60 // Stripe sessions expire after max 24h
    }

    private static let key = "helium_pending_stripe_checkout"

    static func save(_ checkout: PendingCheckout) {
        guard let data = try? JSONEncoder().encode(checkout) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> PendingCheckout? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingCheckout.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func clearIfMatches(sessionId: String) {
        guard let pending = load(), pending.sessionId == sessionId else { return }
        clear()
    }
}

// MARK: - Payment Success Response

public struct PaymentSuccessResponse: Sendable {
    public let productId: String
    public let priceId: String?
    public let expiresAt: Date?
    public let transactionId: String?

    public init(productId: String, priceId: String?, expiresAt: Date? = nil, transactionId: String? = nil) {
        self.productId = productId
        self.priceId = priceId
        self.expiresAt = expiresAt
        self.transactionId = transactionId
    }
}

// MARK: - API Response Types

public struct ExecutePurchaseResponse: Decodable {
    let subscriptionId: String?
    let subscriptionItemId: String?
    let productId: String?
    let priceId: String?
    let paymentIntentId: String?
    let status: String?
    let expiresAt: String?
    let requestId: String?

    /// Canonical transaction ID derivation — used by both execute-purchase and confirm-checkout flows.
    var transactionId: String? {
        subscriptionItemId ?? subscriptionId ?? paymentIntentId
    }

    public func toPaymentSuccessResponse(backupProductId: String = "") -> PaymentSuccessResponse {
        PaymentSuccessResponse(
            productId: productId ?? backupProductId,
            priceId: priceId,
            expiresAt: parseISODate(expiresAt),
            transactionId: transactionId
        )
    }
}

struct PortalSessionResponse: Decodable {
    let portalUrl: String?
    let customerId: String?
    let requestId: String?
}

struct UpdateCustomerMetadataResponse: Decodable {
    let customerId: String?
    let updated: Bool?
    let requestId: String?
}

// MARK: - Error

public enum HeliumStripeAPIError: LocalizedError {
    case serverError(statusCode: Int, message: String)
    case invalidEndpoint(path: String)
    case checkoutSessionNotCompleted
    case notInitialized

    public var errorDescription: String? {
        switch self {
        case .serverError(let statusCode, let message):
            return "Helium Stripe API error (\(statusCode)): \(message)"
        case .invalidEndpoint(let path):
            return "Invalid endpoint \(path)"
        case .checkoutSessionNotCompleted:
            return "Checkout session has not been completed"
        case .notInitialized:
            return "Helium has not been initialized. Call Helium.initialize() before making Stripe API calls."
        }
    }
}

