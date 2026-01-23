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
        
        /// Product IDs from persisted data, used before real transactions are loaded
        var persistedProductIDs: Set<String> = []
        
        func needsTransactionsSync(resetInterval: TimeInterval) -> Bool {
            guard let lastSyncTime = lastTransactionsLoadedTime else { return true }
            return Date().timeIntervalSince(lastSyncTime) > resetInterval
        }
    }
    
    // MARK: - Persistence Constants
    
    private let entitlementsUserDefaultsKey = "heliumPersistedEntitlements"
    private let entitlementsFileName = "helium_entitlements.json"
    private var cache = EntitlementsCache()
    private var updateListenerTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    
    // MARK: - Persistence
    
    /// File URL for entitlements storage.
    private nonisolated var entitlementsFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Helium", isDirectory: true)
            .appendingPathComponent(entitlementsFileName)
    }
    
    /// Loads persisted entitlements from storage
    private func loadPersistedEntitlements() {
        // Try UserDefaults first
        if let data = UserDefaults.standard.data(forKey: entitlementsUserDefaultsKey),
           let decoded = try? JSONDecoder().decode(PersistedEntitlementsData.self, from: data) {
            applyPersistedData(decoded)
            return
        }

        // Fallback to file
        if let fileURL = entitlementsFileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PersistedEntitlementsData.self, from: data) {
            applyPersistedData(decoded)
        }
    }

    /// Applies persisted data to the cache
    private func applyPersistedData(_ data: PersistedEntitlementsData) {
        // Filter to only valid-looking entitlements
        let validEntitlements = data.entitlements.filter { $0.appearsValid() }
        cache.persistedProductIDs = Set(validEntitlements.map { $0.productID })
        HeliumLogger.log(.debug, category: .entitlements, "Loaded \(validEntitlements.count) persisted entitlements")
    }

    /// Persists current entitlements to storage
    private func saveEntitlements() {
        let entitlements = cache.transactions.map { PersistedEntitlement(from: $0) }
        let data = PersistedEntitlementsData(entitlements: entitlements, savedAt: Date())

        guard let encoded = try? JSONEncoder().encode(data) else {
            HeliumLogger.log(.warn, category: .entitlements, "Failed to encode entitlements for persistence")
            return
        }

        // Save to UserDefaults
        UserDefaults.standard.set(encoded, forKey: entitlementsUserDefaultsKey)

        // Also save to file as backup (async)
        Task.detached { [weak self, encoded] in
            await self?.saveEntitlementsToFile(encoded)
        }

        HeliumLogger.log(.debug, category: .entitlements, "Persisted \(entitlements.count) entitlements")
    }

    /// Saves encoded data to file
    private nonisolated func saveEntitlementsToFile(_ data: Data) async {
        guard let fileURL = entitlementsFileURL else { return }

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            HeliumLogger.log(.warn, category: .entitlements, "Failed to persist entitlements to file", metadata: ["error": error.localizedDescription])
        }
    }

    /// Clears persisted entitlements
    private func clearPersistedEntitlements() {
        UserDefaults.standard.removeObject(forKey: entitlementsUserDefaultsKey)

        if let fileURL = entitlementsFileURL {
            Task.detached {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

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
        // Load persisted entitlements first for immediate availability
        loadPersistedEntitlements()
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

        // Clear persisted product IDs since we now have real transactions
        cache.persistedProductIDs.removeAll()

        // Persist the updated entitlements
        saveEntitlements()
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
        if !entitlements.isEmpty { return true }
        // Fallback to persisted data if no transactions loaded
        return !cache.persistedProductIDs.isEmpty
    }
    
    func purchasedProductIds() async -> [String] {
        let entitlements = await getCachedEntitlements()
        var productIds = entitlements.map { $0.productID }
        // Include persisted product IDs not already in the list
        for persistedId in cache.persistedProductIDs {
            if !productIds.contains(persistedId) {
                productIds.append(persistedId)
            }
        }
        return productIds
    }

    /// Returns persisted product IDs synchronously for immediate availability.
    /// This is useful before transactions have been loaded from StoreKit.
    func getPersistedProductIds() -> Set<String> {
        cache.persistedProductIDs
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
        // Check persisted data as fallback
        if cache.persistedProductIDs.contains(productId) {
            return true
        }
        return await hasActiveSubscriptionFor(productId: productId)
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
        clearPersistedEntitlements()
    }
    
    func updateAfterPurchase(productID: String, transaction: Transaction?) async {
        if !cache.transactions.contains(where: { $0.productID == productID }) {
            cache.lastTransactionsLoadedTime = nil
            await loadEntitlementsIfNeeded()
            // If it's still not there, add it manually (if transaction available)
            if let transaction {
                if !cache.transactions.contains(where: { $0.productID == productID }) {
                    cache.transactions.append(transaction)
                    // Persist the updated entitlements
                    saveEntitlements()
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
        var latestStatus: Product.SubscriptionInfo.Status?
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

