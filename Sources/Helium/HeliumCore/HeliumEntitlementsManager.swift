//
//  HeliumEntitlementsManager.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 9/24/25.
//

import StoreKit

actor HeliumEntitlementsManager {
    
    static let shared = HeliumEntitlementsManager()
    
    private let cacheResetInterval: TimeInterval = 60 * 30 // in seconds
    
    /// Debounce interval for transaction updates in seconds
    private let debounceInterval: TimeInterval = 1
    
    // MARK: - Cache Structure
    private struct EntitlementsCache {
        var transactions: [Transaction] = []
        var subscriptionStatuses: [String: Product.SubscriptionInfo.Status] = [:] // productID -> status
        var isLoaded: Bool = false
        var lastLoadedTime: Date?
        
        func needsReset(resetInterval: TimeInterval) -> Bool {
            guard let lastLoadedTime = lastLoadedTime else { return true }
            return Date().timeIntervalSince(lastLoadedTime) > resetInterval
        }
    }
    
    private var cache = EntitlementsCache()
    private var updateListenerTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    
    deinit {
        updateListenerTask?.cancel()
        debounceTask?.cancel()
    }
    
    // MARK: - Transaction Update Listener
    
    private func startTransactionListener() {
        updateListenerTask = Task {
            for await _ in Transaction.updates {
                // Cancel any existing debounce task
                debounceTask?.cancel()
                
                // Create new debounced refresh task
                debounceTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))
                    
                    if !Task.isCancelled {
                        clearCache()
                        await loadEntitlementsIfNeeded()
                    }
                }
            }
        }
    }
    
    // MARK: - Cache Management
    
    private func clearCache() {
        cache = EntitlementsCache()
    }
    
    private var isConfigured = false
    /// Configures the entitlements manager by starting the transaction listener
    /// and performing an initial load of entitlements.
    /// Call this method once during app initialization.
    public func configure() async {
        guard !isConfigured else { return }
        isConfigured = true
        startTransactionListener()
        await loadEntitlementsIfNeeded()
    }
    
    private func loadEntitlementsIfNeeded() async {
        // Check if cache is still valid
        if cache.isLoaded && !cache.needsReset(resetInterval: cacheResetInterval) {
            return
        }
        
        var transactions: [Transaction] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                transactions.append(transaction)
            }
        }
        
        cache.transactions = transactions
        cache.isLoaded = true
        cache.lastLoadedTime = Date()
    }
    
    private func getCachedEntitlements() async -> [Transaction] {
        await loadEntitlementsIfNeeded()
        return cache.transactions
    }
    
    // MARK: - Public Methods
    
    func hasAnyActiveSubscription(includeNonRenewing: Bool) async -> Bool {
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
    
    func hasAnyEntitlement() async -> Bool {
        let entitlements = await getCachedEntitlements()
        return !entitlements.isEmpty
    }
    
    func purchasedProductIds() async -> [String] {
        let entitlements = await getCachedEntitlements()
        return entitlements.map { $0.productID }
    }
    
    func hasActiveSubscriptionFor(subscriptionGroupID: String) async -> Bool {
        let status = await subscriptionStatusFor(subscriptionGroupID: subscriptionGroupID)
        return isSubscriptionStateActive(status?.state)
    }
    
    func subscriptionStatusFor(subscriptionGroupID: String) async -> Product.SubscriptionInfo.Status? {
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
    
    func hasActiveEntitlementFor(productId: String) async -> Bool {
        let entitlements = await getCachedEntitlements()
        for transaction in entitlements {
            if transaction.productType != .autoRenewable && transaction.productID == productId {
                return true
            }
        }
        return await hasActiveSubscriptionFor(productId: productId)
    }
    
    func hasActiveSubscriptionFor(productId: String) async -> Bool {
        let status = await subscriptionStatusFor(productId: productId)
        return isSubscriptionStateActive(status?.state)
    }
    
    func subscriptionStatusFor(productId: String) async -> Product.SubscriptionInfo.Status? {
        return await getSubscriptionStatus(for: productId)
    }
    
    func activeSubscriptions(includeNonRenewing: Bool) async -> [String: Product.SubscriptionInfo.Status] {
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
    
    /// Clears all cached data and forces a refresh on the next access.
    func invalidateCache() async {
        clearCache()
    }
    
    // MARK: - Private Helper Methods
    
    /// Lazily loads and caches subscription status for a product
    private func getSubscriptionStatus(for productId: String) async -> Product.SubscriptionInfo.Status? {
        // Check if subscription status cache needs refresh based on main cache expiration
        if cache.needsReset(resetInterval: cacheResetInterval) {
            cache.subscriptionStatuses.removeAll()
        }
        
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
    
    /// Checks if a subscription state is considered active
    private func isSubscriptionStateActive(_ state: Product.SubscriptionInfo.RenewalState?) -> Bool {
        guard let state = state else { return false }
        switch state {
        case .subscribed, .inBillingRetryPeriod, .inGracePeriod:
            return true
        case .expired, .revoked:
            return false
        default:
            return false
        }
    }
}

