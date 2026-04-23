import Foundation

/// Which of the configured checkout redirect URLs the user returned through.
enum CheckoutRedirectKind {
    case success
    case cancel
}

// MARK: - URL Constants

enum WebCheckoutRedirect {
    /// Classifies an incoming URL forwarded via `Helium.shared.handleURL(_:)`.
    ///
    /// When the configured success and cancel URLs have distinct paths, the match
    /// alone is authoritative. When they're identical, query params appended by
    /// our checkout flow disambiguate. Returns `nil` if the URL doesn't match, or
    /// if success/cancel collide and query params aren't conclusive — those go to
    /// the didBecomeActive observer, which reconciles against real entitlement state.
    static func classify(_ url: URL) -> CheckoutRedirectKind? {
        let matchesSuccess = matchesBase(url, configured: Helium.config.checkoutSuccessURL)
        let matchesCancel = matchesBase(url, configured: Helium.config.checkoutCancelURL)

        switch (matchesSuccess, matchesCancel) {
        case (false, false):
            return nil
        case (true, false):
            return .success
        case (false, true):
            return .cancel
        case (true, true):
            return classifyByQueryParams(url)
        }
    }

    private static func classifyByQueryParams(_ url: URL) -> CheckoutRedirectKind? {
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        if let transactionId = value("transactionId"), !transactionId.isEmpty {
            return .success
        }
        if value("alreadySubscribed") == "true" {
            return .success
        }
        if let error = value("error"), !error.isEmpty {
            return .cancel
        }
        return nil
    }

    private static func matchesBase(_ url: URL, configured: String?) -> Bool {
        guard let configured, let configuredURL = URL(string: configured) else { return false }
        guard url.scheme == configuredURL.scheme, url.host == configuredURL.host else { return false }

        let configPath = normalizedPath(configuredURL.path)
        let incomingPath = normalizedPath(url.path)

        // Stripe substitutes {CHECKOUT_SESSION_ID} in the URL server-side.
        // If the developer put the placeholder in the path, match the prefix up to it.
        if let marker = configPath.range(of: "{CHECKOUT_SESSION_ID}") {
            return incomingPath.hasPrefix(String(configPath[..<marker.lowerBound]))
        }
        return incomingPath == configPath
    }

    private static func normalizedPath(_ path: String) -> String {
        let value = path.isEmpty ? "/" : path
        guard value.count > 1, value.hasSuffix("/") else { return value }
        return String(value.dropLast())
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

// MARK: - Entitlement Response Types

struct PaymentEntitlementResponse: Codable, Sendable {
    let hasActiveEntitlement: Bool
    let subscriptions: [PaymentSubscriptionInfo]
    let customerId: String?
}

// Stripe and Paddle don't return identical shapes. Stripe emits `trialEnd`;
// Paddle emits `trialStartsAt`/`trialEndsAt` and additional fields
// (`startedAt`, `nextBilledAt`, `currentPeriodStart`, `canceledAt`,
// `scheduledChange`) that we don't currently consume. Add them here if a
// consumer ever needs them.
struct PaymentSubscriptionInfo: Codable, Sendable {
    let subscriptionId: String
    let productId: String
    let status: String
    let priceId: String?
    let productName: String?
    let productDescription: String?
    let currentPeriodEnd: String?
    let cancelAtPeriodEnd: Bool?
    let trialEnd: String?
    let trialEndsAt: String?

    var isActive: Bool {
        ["active", "trialing"].contains(status)
    }
}

// MARK: - Product Entitlement

/// A product entitlement with its subscription expiration date.
struct ProductEntitlement: Codable {
    let productId: String
    let priceId: String?
    /// When the subscription period actually ends.
    /// Nil for one-time purchases (permanent entitlement).
    let subscriptionExpiresAt: Date?

    var isActive: Bool {
        guard let subscriptionExpiresAt else { return true }
        return Date() < subscriptionExpiresAt
    }

    var heliumProductId: String {
        if let priceId { return "\(productId):\(priceId)" }
        return productId
    }
}

struct PersistedPaymentEntitlements: Codable {
    let products: [ProductEntitlement]
}

// MARK: - Error

public enum HeliumPaymentAPIError: LocalizedError {
    case serverError(statusCode: Int, message: String)
    case invalidEndpoint(path: String)
    case checkoutSessionNotCompleted
    case notInitialized

    public var errorDescription: String? {
        switch self {
        case .serverError(let statusCode, let message):
            return "Helium Payment API error (\(statusCode)): \(message)"
        case .invalidEndpoint(let path):
            return "Invalid endpoint \(path)"
        case .checkoutSessionNotCompleted:
            return "Checkout session has not been completed"
        case .notInitialized:
            return "Helium has not been initialized. Call Helium.initialize() before making payment API calls."
        }
    }
}

enum WebCheckoutError: LocalizedError {
    case cannotPresentCheckout
    case checkoutURLsNotConfigured
    case failedToBuildEnrichedURL
    case failedToOpenEnrichedURL
    case webPaywallBundleUrlMissing

    var errorDescription: String? {
        switch self {
        case .cannotPresentCheckout:
            return "Could not present the checkout view"
        case .checkoutURLsNotConfigured:
            return "Checkout URLs not configured. Call Helium.config.enableExternalWebCheckout() before presenting a paywall."
        case .failedToBuildEnrichedURL:
            return "Failed to build enriched checkout URL."
        case .failedToOpenEnrichedURL:
            return "Could not open enriched checkout URL in browser."
        case .webPaywallBundleUrlMissing:
            return "No web paywall bundle URL available for this paywall."
        }
    }
}
