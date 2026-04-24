import Foundation

/// Captures the provider-specific values that differ between Stripe, Paddle, etc.
struct PaymentProviderConfig {
    let displayName: String

    let providerSlug: String
    let customerIdBodyKey: String
    let getCustomerId: () -> String?
    let setCustomerId: (String) -> Void
    let getEntitlementsSource: () -> HeliumPaymentEntitlementsSource
    let initialProductKey: String
    let entitlementsPersistenceFileName: String
    let getCheckoutSuccessURL: () -> String?
    let getCheckoutCancelURL: () -> String?
    /// Products this provider considers "offered" for a given paywall.
    /// `includeInAppSetIfWebEmpty` widens to the in-app Paddle set only when the
    /// web set is empty — used on the success-redirect path as a safety net
    /// against server config drift (web bundle URL present, web products missing).
    let getOfferedProducts: (HeliumPaywallInfo, _ includeInAppSetIfWebEmpty: Bool) -> [String]?
    let purchaseEventPaymentProcessor: HeliumPaymentProcessor

    var checkEntitlementPath: String { "\(providerSlug)/check-entitlement" }
    var updateCustomerMetadataPath: String { "\(providerSlug)/update-customer-metadata" }
    var createPortalSessionPath: String { "\(providerSlug)/create-portal-session" }

    static let stripe = PaymentProviderConfig(
        displayName: "Stripe",
        providerSlug: "stripe",
        customerIdBodyKey: "stripeCustomerId",
        getCustomerId: { HeliumIdentityManager.shared.getStripeCustomerId() },
        setCustomerId: { HeliumIdentityManager.shared.setStripeCustomerId($0) },
        getEntitlementsSource: { HeliumEntitlementsManager.shared.stripeEntitlementsSource },
        initialProductKey: "initialStripeSelection",
        entitlementsPersistenceFileName: "helium_stripe_entitlements.json",
        getCheckoutSuccessURL: { Helium.config.checkoutSuccessURL },
        getCheckoutCancelURL: { Helium.config.checkoutCancelURL },
        getOfferedProducts: { paywallInfo, _ in paywallInfo.productsOfferedStripe },
        purchaseEventPaymentProcessor: .stripe
    )

    static let paddle = PaymentProviderConfig(
        displayName: "Paddle",
        providerSlug: "paddle",
        customerIdBodyKey: "paddleCustomerId",
        getCustomerId: { HeliumIdentityManager.shared.getPaddleCustomerId() },
        setCustomerId: { HeliumIdentityManager.shared.setPaddleCustomerId($0) },
        getEntitlementsSource: { HeliumEntitlementsManager.shared.paddleEntitlementsSource },
        initialProductKey: "initialPaddleSelection",
        entitlementsPersistenceFileName: "helium_paddle_entitlements.json",
        getCheckoutSuccessURL: { Helium.config.checkoutSuccessURL },
        getCheckoutCancelURL: { Helium.config.checkoutCancelURL },
        getOfferedProducts: { paywallInfo, includeInAppSetIfWebEmpty in
            if let web = paywallInfo.webProductsOfferedPaddle, !web.isEmpty {
                return web
            }
            return includeInAppSetIfWebEmpty ? paywallInfo.productsOfferedPaddle : nil
        },
        purchaseEventPaymentProcessor: .paddle
    )
}
