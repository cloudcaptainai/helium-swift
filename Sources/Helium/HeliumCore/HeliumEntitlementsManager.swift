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
    
    private struct SubscriptionStatusCache {
        let status: Product.SubscriptionInfo.Status
        let syncTime: Date
    }
    
    // MARK: - Cache Structure
    private struct EntitlementsCache {
        var transactions: [Transaction] = []
        var subscriptionStatuses: [String: SubscriptionStatusCache] = [:] // productID is key
        
        var lastTransactionsLoadedTime: Date?
        
        func needsTransactionsSync(resetInterval: TimeInterval) -> Bool {
            guard let lastSyncTime = lastTransactionsLoadedTime else { return true }
            return Date().timeIntervalSince(lastSyncTime) > resetInterval
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
                        cache.lastTransactionsLoadedTime = nil
                        await loadEntitlementsIfNeeded()
                    }
                }
            }
        }
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
        if !cache.needsTransactionsSync(resetInterval: cacheResetInterval) {
            return
        }
        
        var transactions: [Transaction] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                // Skip consumables - they don't represent ongoing entitlements
                if transaction.productType == .consumable {
                    continue
                }
                if transaction.productType == .nonRenewable {
                    let nonRenewingExpired = transaction.expirationDate != nil && transaction.expirationDate! < Date()
                    if nonRenewingExpired {
                        continue
                    }
                }
                transactions.append(transaction)
            }
        }
        
        cache.transactions = transactions
        cache.lastTransactionsLoadedTime = Date()
    }
    
    private func getCachedEntitlements() async -> [Transaction] {
        await loadEntitlementsIfNeeded()
        return cache.transactions
    }
    
    // MARK: - Public Methods
    
    func hasEntitlementForPaywall(
        trigger: String,
        considerAssociatedSubscriptions: Bool
    ) async -> Bool? {
        if !Helium.shared.paywallsLoaded() {
            return nil
        }
        
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger) ?? HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger)
        
        let productIds = paywallInfo?.productsOffered ?? []
        
        // Just see if any of the paywall products are purchased/active
        if !considerAssociatedSubscriptions {
            return await purchasedProductIds().contains { productIds.contains($0) }
        }
        
        // Otherwise check products and associated subscription groups
        for productId in productIds {
            let entitled = await hasActiveEntitlementFor(productId: productId)
            if entitled {
                return true
            }
        }
        
        return false
    }
    
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
        let entitlements = await getCachedEntitlements()
        
        for transaction in entitlements where transaction.productType == .autoRenewable {
            if transaction.subscriptionGroupID == subscriptionGroupID {
                return true
            }
        }
        return false
    }
    
    func subscriptionStatusFor(subscriptionGroupID: String) async -> Product.SubscriptionInfo.Status? {
        let entitlements = await getCachedEntitlements()
        
        for transaction in entitlements where transaction.productType == .autoRenewable {
            if transaction.subscriptionGroupID == subscriptionGroupID {
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
            if transaction.productID == productId {
                return true
            }
        }
        return await hasActiveSubscriptionFor(productId: productId)
    }

    /// Checks if user has personally purchased this exact product (excludes family sharing).
    /// Note: This checks the exact productId only, not subscription group membership.
    func hasPersonallyPurchased(productId: String) async -> Bool {
        let entitlements = await getCachedEntitlements()
        for transaction in entitlements {
            if transaction.productID == productId && transaction.ownershipType == .purchased {
                return true
            }
        }
        return false
    }

    // Note that this should return true if user has purchased product OR a different subscription within same subscription group as supplied product.
    func hasActiveSubscriptionFor(productId: String) async -> Bool {
        let entitlements = await getCachedEntitlements()
        for transaction in entitlements {
            if transaction.productID == productId
                && (transaction.productType == .autoRenewable || transaction.productType == .nonRenewable) {
                return true
            }
        }
        
        let status = await subscriptionStatusFor(productId: productId)
        return isSubscriptionStateActive(status?.state)
    }
    
    func subscriptionStatusFor(productId: String) async -> Product.SubscriptionInfo.Status? {
        return await getSubscriptionStatus(for: productId)
    }
    
    func activeSubscriptions() async -> [String: Product.SubscriptionInfo] {
        let entitlements = await getCachedEntitlements()
        var subscriptions: [String: Product.SubscriptionInfo] = [:]
        
        for transaction in entitlements {
            if transaction.productType == .autoRenewable,
               let product = try? await ProductsCache.shared.getProduct(id: transaction.productID),
               let subscription = product.subscription {
                subscriptions[transaction.productID] = subscription
            }
        }
        
        return subscriptions
    }
    
    /// Clears all cached data and forces a refresh on the next access.
    func invalidateCache() async {
        cache = EntitlementsCache()
    }
    
    func updateAfterPurchase(productID: String, transaction: Transaction?) async {
        // Skip consumables - they don't represent ongoing entitlements
        if transaction?.productType == .consumable {
            return
        }

        if !cache.transactions.contains(where: { $0.productID == productID }) {
            cache.lastTransactionsLoadedTime = nil
            await loadEntitlementsIfNeeded()
            // If it's still not there, add it manually (if transaction available)
            if let transaction {
                if !cache.transactions.contains(where: { $0.productID == productID }) {
                    cache.transactions.append(transaction)
                }
            } else {
                cache.lastTransactionsLoadedTime = nil
            }
        }
        
        cache.subscriptionStatuses[productID] = nil
        let _ = await getSubscriptionStatus(for: productID)
    }
    
    // MARK: - Private Helper Methods
    
    /// Lazily loads and caches (auto-renewable) subscription status for a product
    private func getSubscriptionStatus(for productId: String) async -> Product.SubscriptionInfo.Status? {
        // Check cache first
        if let cachedStatus = cache.subscriptionStatuses[productId] {
            if Date().timeIntervalSince(cachedStatus.syncTime) < cacheResetInterval {
                return cachedStatus.status
            }
        }
        
        // Load and cache
        guard let product = try? await ProductsCache.shared.getProduct(id: productId) else {
            return nil
        }
        
        guard let statusList = try? await product.subscription?.status else {
            return nil
        }
        var latestStatus: Product.SubscriptionInfo.Status? = nil
        for statusOption in statusList {
            if isSubscriptionStateActive(statusOption.state) {
                if latestStatus == nil {
                    latestStatus = statusOption
                } else {
                    // Compare expiration dates and set latestStatus to the later expiration date
                    let currentExpiration: Date?
                    let newExpiration: Date?

                    // Extract expiration dates from verified renewal info
                    if case .verified(let currentRenewalInfo) = latestStatus?.renewalInfo {
                        currentExpiration = currentRenewalInfo.renewalDate
                    } else {
                        currentExpiration = nil
                    }

                    if case .verified(let newRenewalInfo) = statusOption.renewalInfo {
                        newExpiration = newRenewalInfo.renewalDate
                    } else {
                        newExpiration = nil
                    }

                    // If new status has no expiration or expires later, use it
                    if let newExp = newExpiration {
                        if let currentExp = currentExpiration {
                            // Both have expiration dates, keep the later one
                            if newExp > currentExp {
                                latestStatus = statusOption
                            }
                        } else {
                            // Current has no expiration but new does, keep current (lifetime)
                        }
                    } else {
                        // New has no expiration, prefer it
                        latestStatus = statusOption
                    }
                }
            }
        }
        
        guard let status = latestStatus else {
            return nil
        }
        // Cache the status
        cache.subscriptionStatuses[productId] = SubscriptionStatusCache(status: status, syncTime: Date())
        return status
    }
    
    /// Checks if a subscription state is considered active
    private func isSubscriptionStateActive(_ state: Product.SubscriptionInfo.RenewalState?) -> Bool {
        guard let state = state else { return false }
        // including inBillingRetryPeriod as true but note that Transaction.currentEntitlements does not seem to include inBillingRetryPeriod
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

