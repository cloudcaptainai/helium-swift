import Foundation

// MARK: - Checkout Style

/// Controls how Stripe Checkout is presented
public enum StripeCheckoutStyle: Sendable {
    /// Embedded WKWebView (default). No deep link setup required.
    case webView
    /// SFSafariViewController. The SDK automatically detects when the user returns.
    case safariInApp
    /// Opens in the default browser. The SDK automatically detects when the user returns.
    case externalBrowser
}

// MARK: - Checkout Result

public enum StripeCheckoutResult {
    case success(sessionId: String?)
    case cancelled
    case failed(Error)
}

// MARK: - URL Constants

enum StripeCheckoutRedirect {
    static var basePath: String { "\(HeliumStripeAPIClient.shared.heliumBaseURL)stripe/checkout" }
    static let successPath = "/success"
    static let cancelPath = "/cancel"

    static var successURL: String { "\(basePath)\(successPath)?session_id={CHECKOUT_SESSION_ID}" }
    static var cancelURL: String { "\(basePath)\(cancelPath)" }

    static func isSuccess(_ url: URL) -> Bool {
        url.absoluteString.hasPrefix("\(basePath)\(successPath)")
    }

    static func isCancelled(_ url: URL) -> Bool {
        url.absoluteString.hasPrefix("\(basePath)\(cancelPath)")
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
}

// MARK: - Payment Success Response

public struct PaymentSuccessResponse: Sendable {
    public let productId: String
    public let expiresAt: Date?
    public let transactionId: String?

    public init(productId: String, expiresAt: Date? = nil, transactionId: String? = nil) {
        self.productId = productId
        self.expiresAt = expiresAt
        self.transactionId = transactionId
    }
}

// MARK: - API Response Types

struct ExecutePurchaseResponse: Decodable {
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

    func toPaymentSuccessResponse(backupProductId: String = "") -> PaymentSuccessResponse {
        PaymentSuccessResponse(
            productId: productId ?? backupProductId,
            expiresAt: parseISODate(expiresAt),
            transactionId: transactionId
        )
    }
}

struct CheckoutSessionResponse: Decodable {
    let checkoutURL: String?
    let sessionId: String?
    let stripeCustomerId: String?
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

    public var errorDescription: String? {
        switch self {
        case .serverError(let statusCode, let message):
            return "Helium Stripe API error (\(statusCode)): \(message)"
        case .invalidEndpoint(let path):
            return "Invalid endpoint \(path)"
        case .checkoutSessionNotCompleted:
            return "Checkout session has not been completed"
        }
    }
}

