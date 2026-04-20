import Foundation

/// Captures the provider-specific values that differ between Stripe, Paddle, etc.
struct PaymentProviderConfig {
    let displayName: String
    
    let providerSlug: String
    let customerIdBodyKey: String
    let getCustomerId: () -> String?
    let setCustomerId: (String) -> Void
    let initialProductKey: String
    let entitlementsPersistenceFileName: String
    let getCheckoutSuccessURL: () -> String?
    let getCheckoutCancelURL: () -> String?
    let getOfferedProducts: (HeliumPaywallInfo) -> [String]?

    var checkEntitlementPath: String { "\(providerSlug)/check-entitlement" }
    var updateCustomerMetadataPath: String { "\(providerSlug)/update-customer-metadata" }
    var createPortalSessionPath: String { "\(providerSlug)/create-portal-session" }

    static let stripe = PaymentProviderConfig(
        displayName: "Stripe",
        providerSlug: "stripe",
        customerIdBodyKey: "stripeCustomerId",
        getCustomerId: { HeliumIdentityManager.shared.getStripeCustomerId() },
        setCustomerId: { HeliumIdentityManager.shared.setStripeCustomerId($0) },
        initialProductKey: "initialStripeSelection",
        entitlementsPersistenceFileName: "helium_stripe_entitlements.json",
        getCheckoutSuccessURL: { Helium.config.checkoutSuccessURL },
        getCheckoutCancelURL: { Helium.config.checkoutCancelURL },
        getOfferedProducts: { $0.productsOfferedStripe }
    )
    
    static let paddle = PaymentProviderConfig(
        displayName: "Paddle",
        providerSlug: "paddle",
        customerIdBodyKey: "paddleCustomerId",
        getCustomerId: { HeliumIdentityManager.shared.getPaddleCustomerId() },
        setCustomerId: { HeliumIdentityManager.shared.setPaddleCustomerId($0) },
        initialProductKey: "initialPaddleSelection",
        entitlementsPersistenceFileName: "helium_paddle_entitlements.json",
        getCheckoutSuccessURL: { Helium.config.checkoutSuccessURL },
        getCheckoutCancelURL: { Helium.config.checkoutCancelURL },
        getOfferedProducts: { $0.productsOfferedPaddle }
    )
}
