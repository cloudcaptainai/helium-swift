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

        let source: HeliumPaymentEntitlementsSource = paymentProcessor == .stripe
            ? HeliumEntitlementsManager.shared.stripeEntitlementsSource
            : HeliumEntitlementsManager.shared.paddleEntitlementsSource
        let productId = String(productKey.prefix(while: { $0 != ":" }))
        // Ownership is product-level, so list every owned price of the selected product — the selected
        // price may not be the one actually owned.
        let owned = source.entitlements(forProductId: productId)

        var debugLines = ["DEBUG/TESTFLIGHT DETAILS", "", "Selected: \(productKey)", ""]
        if owned.isEmpty {
            debugLines.append("Owned: none found")
        } else {
            debugLines.append("Owned:")
            for (index, entitlement) in owned.enumerated() {
                if index > 0 { debugLines.append("") }
                debugLines.append(entitlement.heliumProductId)
                if let startedAt = entitlement.subscriptionStartedAt {
                    debugLines.append("Started \(formatDateForDisplay(startedAt))")
                }
                if let expiresAt = entitlement.subscriptionExpiresAt {
                    debugLines.append("Until \(formatDateForDisplay(expiresAt))")
                }
            }
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
