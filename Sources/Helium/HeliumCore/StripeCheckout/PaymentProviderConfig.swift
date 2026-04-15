import Foundation

/// Captures the provider-specific values that differ between Stripe, Paddle, etc.
struct PaymentProviderConfig {
    let displayName: String
    
    let providerSlug: String
    let customerIdBodyKey: String
    let getCustomerId: () -> String?
    let setCustomerId: (String) -> Void
    let entitlementsPersistenceFileName: String
    let getSuccessURL: () -> String?
    let getCancelURL: () -> String?
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
        entitlementsPersistenceFileName: "helium_stripe_entitlements.json",
        getSuccessURL: { Helium.config.stripeCheckoutSuccessURL },
        getCancelURL: { Helium.config.stripeCheckoutCancelURL },
        getOfferedProducts: { $0.productsOfferedStripe }
    )
}
