//
//  WebCheckoutAlreadyPurchasedConfig.swift
//  helium-swift
//

import Foundation

public class WebCheckoutAlreadyPurchasedConfig {
    init() {}

    private static let defaultShowHeliumDialog = true

    private(set) var showHeliumDialog: Bool = defaultShowHeliumDialog

    let title = "Already Purchased"
    let message = "You already own this product. Contact support if you have any issues."
    let closeButtonText = "OK"

    /// The message to show in the already-owned dialog. Outside production it appends developer-only
    /// details (the product key, subscription dates, and a reset tip) beneath the production copy.
    func alreadyOwnedMessage(productKey: String, paymentProcessor: HeliumPaymentProcessor) -> String {
        guard AppReceiptsHelper.shared.environment != .production else {
            return message
        }

        var debugLines = ["DEBUG/TESTFLIGHT DETAILS", "", "Product: \(productKey)"]
        let source: HeliumPaymentEntitlementsSource = paymentProcessor == .stripe
            ? HeliumEntitlementsManager.shared.stripeEntitlementsSource
            : HeliumEntitlementsManager.shared.paddleEntitlementsSource
        let productId = String(productKey.prefix(while: { $0 != ":" }))
        let entitlement = source.entitlement(forProductId: productId)
        if let startedAt = entitlement?.subscriptionStartedAt {
            debugLines.append("Started: \(formatDateForDisplay(startedAt))")
        }
        if let expiresAt = entitlement?.subscriptionExpiresAt {
            debugLines.append("Renews/expires: \(formatDateForDisplay(expiresAt))")
        }
        debugLines.append("")
        debugLines.append("Delete and reinstall the app to be treated as a fresh user.")

        return message + "\n\n" + debugLines.joined(separator: "\n")
    }

    /// Disable the default dialog that Helium displays when a web checkout purchase attempt resolves as already owned.
    public func disable() {
        showHeliumDialog = false
    }

    /// Resets configuration to defaults.
    public func reset() {
        showHeliumDialog = Self.defaultShowHeliumDialog
    }

}
