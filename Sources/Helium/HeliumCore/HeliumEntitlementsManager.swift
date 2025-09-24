//
//  HeliumEntitlementsManager.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 9/24/25.
//

import StoreKit

actor HeliumEntitlementsManager {
    
    static let shared = HeliumEntitlementsManager()
    
    // MARK: - Cache Structure
    private struct EntitlementsCache {
        var transactions: [Transaction] = []
        var subscriptionStatuses: [String: Product.SubscriptionInfo.Status] = [:] // productID -> status
        var isLoaded: Bool = false
    }
    
    private var cache = EntitlementsCache()
    private var updateListenerTask: Task<Void, Never>?
    
    deinit {
        updateListenerTask?.cancel()
    }
    
    // MARK: - Transaction Update Listener
    private func startTransactionListener() {
        updateListenerTask = Task {
            for await _ in Transaction.updates {
                clearCache()
            }
        }
    }
    
    // MARK: - Cache Management
    private func clearCache() {
        cache = EntitlementsCache()
    }
    
    public func configure() async {
        startTransactionListener()
        await loadEntitlementsIfNeeded()
    }
    
    private func loadEntitlementsIfNeeded() async {
        guard !cache.isLoaded else { return }
        
        var transactions: [Transaction] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                transactions.append(transaction)
            }
        }
        
        cache.transactions = transactions
        cache.isLoaded = true
    }
    
    private func getCachedEntitlements() async -> [Transaction] {
        await loadEntitlementsIfNeeded()
        return cache.transactions
    }
    
    // MARK: - Public Methods
    
    // does not include consumables
    public func hasAnyActiveSubscription(includeNonRenewing: Bool = true) async -> Bool {
        let entitlements = await getCachedEntitlements()
        
        for transaction in entitlements {
            if transaction.productType == .autoRenewable {
                return true
            } else if includeNonRenewing && transaction.productType == .nonRenewable {
                return true
            }
        }
        return false
    }
    
    // does not include consumables
    public func hasAnyEntitlement() async -> Bool {
        let entitlements = await getCachedEntitlements()
        return !entitlements.isEmpty
    }
    
    // does not include consumables
    public func purchasedProductIds() async -> [String] {
        let entitlements = await getCachedEntitlements()
        return entitlements.map { $0.productID }
    }
    
    public func hasActiveEntitlementFor(subscriptionGroupID: String) async -> Bool {
        let subscriptionState = await subscriptionStatusFor(subscriptionGroupID: subscriptionGroupID)?.state
        return subscriptionState != .expired && subscriptionState != .revoked
    }
    
    public func subscriptionStatusFor(subscriptionGroupID: String) async -> Product.SubscriptionInfo.Status? {
        let entitlements = await getCachedEntitlements()
        
        for transaction in entitlements where transaction.productType == .autoRenewable {
            if let product = try? await ProductsCache.shared.getProduct(id: transaction.productID),
               product.subscription?.subscriptionGroupID == subscriptionGroupID {
                // Get status from cache or load it
                let status = await getSubscriptionStatus(for: transaction.productID)
                return status
            }
        }
        return nil
    }
    
    public func hasActiveEntitlementFor(productId: String) async -> Bool {
        let subscriptionState = await subscriptionStatusFor(productId: productId)?.state
        return subscriptionState != .expired && subscriptionState != .revoked
    }
    
    public func subscriptionStatusFor(productId: String) async -> Product.SubscriptionInfo.Status? {
        return await getSubscriptionStatus(for: productId)
    }
    
    public func activeSubscriptions(includeNonRenewing: Bool = true) async -> [String: Product.SubscriptionInfo.Status] {
        let entitlements = await getCachedEntitlements()
        var subscriptions: [String: Product.SubscriptionInfo.Status] = [:]
        
        for transaction in entitlements {
            if transaction.productType == .autoRenewable ||
                (includeNonRenewing && transaction.productType == .nonRenewable) {
                if let status = await getSubscriptionStatus(for: transaction.productID) {
                    subscriptions[transaction.productID] = status
                }
            }
        }
        
        return subscriptions
    }
    
    // MARK: - Private Helper for Lazy Loading Subscription Status
    private func getSubscriptionStatus(for productId: String) async -> Product.SubscriptionInfo.Status? {
        // Check cache first
        if let cachedStatus = cache.subscriptionStatuses[productId] {
            return cachedStatus
        }
        
        // Load and cache if not found
        guard let product = try? await ProductsCache.shared.getProduct(id: productId),
              let status = try? await product.subscription?.status.first else {
            return nil
        }
        
        // Cache the status
        cache.subscriptionStatuses[productId] = status
        return status
    }
}

