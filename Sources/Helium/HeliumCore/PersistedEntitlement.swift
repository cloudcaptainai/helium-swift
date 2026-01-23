//
//  PersistedEntitlement.swift
//  helium-swift
//
//  Created by Ryan VanAlstine on 1/22/26.
//

import StoreKit

struct PersistedEntitlement: Codable {
    let productID: String
    let productType: String // "autoRenewable", "nonRenewable", "consumable", "nonConsumable"
    let subscriptionGroupID: String?
    let expirationDate: Date?
    let purchaseDate: Date
    let originalPurchaseDate: Date
    let persistedAt: Date

    init(from transaction: Transaction) {
        productID = transaction.productID
        subscriptionGroupID = transaction.subscriptionGroupID
        expirationDate = transaction.expirationDate
        purchaseDate = transaction.purchaseDate
        originalPurchaseDate = transaction.originalPurchaseDate
        persistedAt = Date()

        switch transaction.productType {
        case .autoRenewable:
            productType = "autoRenewable"
        case .nonRenewable:
            productType = "nonRenewable"
        case .consumable:
            productType = "consumable"
        case .nonConsumable:
            productType = "nonConsumable"
        default:
            productType = "unknown"
        }
    }

    /// Check if this persisted entitlement appears to still be valid
    /// For subscriptions with expiration dates, checks if not expired
    /// For lifetime purchases, always returns true
    func appearsValid() -> Bool {
        if let expiration = expirationDate {
            return expiration > Date()
        }
        // No expiration = lifetime purchase or non-expiring entitlement
        return true
    }
}

/// Container for persisted entitlements data
struct PersistedEntitlementsData: Codable {
    let entitlements: [PersistedEntitlement]
    let savedAt: Date
}
