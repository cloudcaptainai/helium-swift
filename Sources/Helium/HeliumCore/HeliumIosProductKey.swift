import Foundation

/// Splits an iOS product key of the form `<productId>:<promoOfferId>` into its parts.
/// A colon in an iOS key means a paired promotional offer; Android-style base plan
/// composites never reach this SDK, and Stripe/Paddle composite keys are left intact.
enum HeliumIosProductKey {
    static func split(_ key: String) -> (productId: String, promoOfferId: String?) {
        if HeliumPaymentProcessor.isWebProcessorCompositeKey(key) {
            return (key, nil)
        }
        guard let separator = key.firstIndex(of: ":") else {
            return (key, nil)
        }
        let offerId = String(key[key.index(after: separator)...])
        return (String(key[..<separator]), offerId.isEmpty ? nil : offerId)
    }

    static func productId(_ key: String) -> String {
        split(key).productId
    }
}
