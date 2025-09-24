//
//  HeliumEntitlementsManager.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 9/24/25.
//

import StoreKit

class HeliumEntitlementsManager {
    
    static let shared = HeliumEntitlementsManager()
    
    // does not include consumables
    public func hasAnyActiveSubscription(includeNonRenewing: Bool = true) async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                if transaction.productType == .autoRenewable {
                    return true
                } else if includeNonRenewing && transaction.productType == .nonRenewable {
                    return true
                }
            }
        }
        return false
    }
    
    // does not include consumables
    public func hasAnyEntitlement() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                return true
            }
        }
        return false
    }
    
    // does not include consumables
    public func purchasedProductIds() async -> [String] {
        var ids: [String] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                ids.append(transaction.productID)
            }
        }
        return ids
    }
    
    public func hasActiveEntitlementFor(subscriptionGroupID: String) async -> Bool {
        let subcriptionState = await subscriptionStatusFor(subscriptionGroupID: subscriptionGroupID)?.state
        return subcriptionState != .expired && subcriptionState != .revoked
    }
    
    public func subscriptionStatusFor(subscriptionGroupID: String) async -> Product.SubscriptionInfo.Status? {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productType == .autoRenewable {
                if let product = try? await ProductsCache.shared.getProduct(id: transaction.productID),
                   let status = try? await product.subscription?.status.first {
                    if product.subscription?.subscriptionGroupID == subscriptionGroupID {
                        return status
                    }
                }
            }
        }
        return nil
    }
    
    public func hasActiveEntitlementFor(productId: String) async -> Bool {
        let subcriptionState = await subscriptionStatusFor(productId: productId)?.state
        return subcriptionState != .expired && subcriptionState != .revoked
    }
    
    public func subscriptionStatusFor(productId: String) async -> Product.SubscriptionInfo.Status? {
        guard let product = try? await ProductsCache.shared.getProduct(id: productId),
              let status = try? await product.subscription?.status.first else {
            return nil
        }
        return status
    }
    
    public func activeSubscriptions() async -> [String: Product.SubscriptionInfo.Status] {
        var subscriptions: [String: Product.SubscriptionInfo.Status] = [:]
        
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productType == .autoRenewable {
                if let product = try? await ProductsCache.shared.getProduct(id: transaction.productID),
                   let status = try? await product.subscription?.status.first {
                    subscriptions[transaction.productID] = status
                }
            }
        }
        
        return subscriptions
    }
    
}

