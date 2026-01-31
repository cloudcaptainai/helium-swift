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
    let ownershipType: String // "purchased", "familyShared"

    init(from transaction: Transaction) {
        productID = transaction.productID
        subscriptionGroupID = transaction.subscriptionGroupID
        expirationDate = transaction.expirationDate

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

        switch transaction.ownershipType {
        case .purchased:
            ownershipType = "purchased"
        case .familyShared:
            ownershipType = "familyShared"
        default:
            ownershipType = "purchased"
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

    var isAutoRenewable: Bool {
        productType == "autoRenewable"
    }

    var isNonRenewable: Bool {
        productType == "nonRenewable"
    }

    var isConsumable: Bool {
        productType == "consumable"
    }

    var isSubscription: Bool {
        isAutoRenewable || isNonRenewable
    }

    // If true, the user owns this purchase. In other words, they don't have entitlement due to family sharing.
    var isPersonalPurchase: Bool {
        ownershipType == "purchased"
    }
}

/// Container for persisted entitlements data
struct PersistedEntitlementsData: Codable {
    let entitlements: [PersistedEntitlement]
    let entitledForTrigger: [String: Bool]

    init(entitlements: [PersistedEntitlement], entitledForTrigger: [String: Bool] = [:]) {
        self.entitlements = entitlements
        self.entitledForTrigger = entitledForTrigger
    }

    // Custom decoding to handle missing entitledForTrigger in older persisted data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entitlements = try container.decode([PersistedEntitlement].self, forKey: .entitlements)
        entitledForTrigger = try container.decodeIfPresent([String: Bool].self, forKey: .entitledForTrigger) ?? [:]
    }
}
