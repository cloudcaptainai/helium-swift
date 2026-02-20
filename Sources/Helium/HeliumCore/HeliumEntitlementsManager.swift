//
//  HeliumEntitlementsManager.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 9/24/25.
//

import StoreKit

actor HeliumEntitlementsManager {
    
    static let shared = HeliumEntitlementsManager()
    
    private nonisolated var thirdPartySource: ThirdPartyEntitlementsSource? {
        Helium.config.thirdPartyEntitlementsSource
    }
    
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

        /// Entitlements from persisted data, used before real transactions are loaded
        var persistedEntitlements: [PersistedEntitlement] = []

        /// Cached entitlement status per trigger, persisted for use before paywalls load
        var entitledForTrigger: [String: Bool] = [:]

        func needsTransactionsSync(resetInterval: TimeInterval) -> Bool {
            guard let lastSyncTime = lastTransactionsLoadedTime else { return true }
            return Date().timeIntervalSince(lastSyncTime) > resetInterval
        }
    }
    
    // MARK: - Persistence Constants

    private let entitlementsFileName = "helium_entitlements.json"
    private var cache = EntitlementsCache()
    private var updateListenerTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var configDownloadObserver: NSObjectProtocol?
    
    // MARK: - Persistence
    
    /// File URL for entitlements storage.
    private nonisolated var entitlementsFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Helium", isDirectory: true)
            .appendingPathComponent(entitlementsFileName)
    }
    
    /// Loads persisted entitlements from file storage
    private func loadPersistedEntitlements() {
        guard let fileURL = entitlementsFileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistedEntitlementsData.self, from: data) else {
            return
        }
        applyPersistedData(decoded)
    }

    /// Applies persisted data to the cache
    private func applyPersistedData(_ data: PersistedEntitlementsData) {
        // Filter to only valid, non-consumable entitlements
        cache.persistedEntitlements = data.entitlements.filter { $0.appearsValid() && !$0.isConsumable }
        cache.entitledForTrigger = data.entitledForTrigger
        HeliumLogger.log(.debug, category: .entitlements, "Loaded \(cache.persistedEntitlements.count) persisted entitlements, \(cache.entitledForTrigger.count) trigger entitlements")
    }

    /// Persists current entitlements to file storage
    private func saveEntitlements() {
        guard let fileURL = entitlementsFileURL else { return }

        // Filter out consumables - they don't represent ongoing entitlements
        let entitlements = cache.transactions
            .filter { $0.productType != .consumable }
            .map { PersistedEntitlement(from: $0) }
        let data = PersistedEntitlementsData(
            entitlements: entitlements,
            entitledForTrigger: cache.entitledForTrigger
        )

        guard let encoded = try? JSONEncoder().encode(data) else {
            HeliumLogger.log(.warn, category: .entitlements, "Failed to encode entitlements for persistence")
            return
        }

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoded.write(to: fileURL, options: .atomic)
            HeliumLogger.log(.debug, category: .entitlements, "Persisted \(entitlements.count) entitlements")
        } catch {
            HeliumLogger.log(.warn, category: .entitlements, "Failed to persist entitlements to file", metadata: ["error": error.localizedDescription])
        }
    }

    /// Clears persisted entitlements
    private func clearPersistedEntitlements() {
        guard let fileURL = entitlementsFileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    deinit {
        updateListenerTask?.cancel()
        debounceTask?.cancel()
        if let observer = configDownloadObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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

        // Refresh trigger entitlement cache now or when config finishes downloading
        if Helium.shared.paywallsLoaded() {
            await refreshEntitledForTriggerCache()
        } else {
            setupConfigDownloadObserver()
        }
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

        // If StoreKit returned transactions, use them and update persistence
        if !transactions.isEmpty {
            cache.transactions = transactions
            cache.lastTransactionsLoadedTime = Date()
            cache.persistedEntitlements.removeAll()
            saveEntitlements()
            return
        }

        // StoreKit returned empty - check if we should trust this result
        // If persisted entitlements have all expired, trust the empty result
        let hasValidPersistedEntitlements = cache.persistedEntitlements.contains { $0.appearsValid() }

        if hasValidPersistedEntitlements {
            // We have non-expired persisted entitlements but StoreKit returned empty
            // This could be a StoreKit sync issue (offline, not ready, etc.)
            // Keep persisted data and don't mark as loaded so we retry next time
            HeliumLogger.log(.warn, category: .entitlements,
                "StoreKit returned no transactions but valid persisted entitlements exist - keeping persisted data")
        } else {
            // All persisted entitlements are expired or none exist - trust empty result
            cache.transactions = []
            cache.lastTransactionsLoadedTime = Date()
            cache.persistedEntitlements.removeAll()
            saveEntitlements()
        }
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
        // If paywalls haven't loaded yet, use persisted trigger entitlement if available
        if !Helium.shared.paywallsLoaded() {
            return cache.entitledForTrigger[trigger]
        }

        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger) ?? HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger)

        let productIds = paywallInfo?.productIds ?? []

        var result: Bool

        // Just see if any of the paywall products are purchased/active
        if !considerAssociatedSubscriptions {
            result = await purchasedProductIds().contains { productIds.contains($0) }
        } else {
            // Otherwise check products and associated subscription groups
            result = false
            for productId in productIds {
                let entitled = await hasActiveEntitlementFor(productId: productId)
                if entitled {
                    result = true
                    break
                }
            }
        }

        // Cache and persist the result for this trigger
        if cache.entitledForTrigger[trigger] != result {
            cache.entitledForTrigger[trigger] = result
            saveEntitlements()
        }

        return result
    }
    
    func hasAnyActiveSubscription(includeNonRenewing: Bool) async -> Bool {
        // Check third-party source
        if let source = thirdPartySource,
           await source.hasAnyActiveSubscription() {
            return true
        }
        
        // If transactions haven't loaded yet, use persisted data immediately for faster response
        if cache.lastTransactionsLoadedTime == nil {
            for persisted in cache.persistedEntitlements where persisted.appearsValid() {
                if persisted.isAutoRenewable {
                    return true
                } else if includeNonRenewing && persisted.isNonRenewable {
                    return true
                }
            }
        }

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
        // Check third-party source
        if let thirdPartyIds = await thirdPartySource?.entitledProductIds(),
           !thirdPartyIds.isEmpty {
            return true
        }
        
        // If transactions haven't loaded yet, use persisted data immediately for faster response
        if cache.lastTransactionsLoadedTime == nil {
            if cache.persistedEntitlements.contains(where: { $0.appearsValid() }) {
                return true
            }
        }
        let entitlements = await getCachedEntitlements()
        return !entitlements.isEmpty
    }
    
    func purchasedProductIds() async -> [String] {
        // If transactions haven't loaded yet, use persisted data immediately for faster response
        if cache.lastTransactionsLoadedTime == nil {
            let validPersisted = cache.persistedEntitlements.filter { $0.appearsValid() }
            if !validPersisted.isEmpty {
                var ids = Set(validPersisted.map { $0.productID })
                if let thirdPartyIds = await thirdPartySource?.entitledProductIds() {
                    ids.formUnion(thirdPartyIds)
                }
                return Array(ids)
            }
        }
        let entitlements = await getCachedEntitlements()
        var ids = Set(entitlements.map { $0.productID })
        if let thirdPartyIds = await thirdPartySource?.entitledProductIds() {
            ids.formUnion(thirdPartyIds)
        }
        return Array(ids)
    }

    func hasActiveSubscriptionFor(subscriptionGroupID: String) async -> Bool {
        // If transactions haven't loaded yet, use persisted data immediately for faster response
        if cache.lastTransactionsLoadedTime == nil {
            for persisted in cache.persistedEntitlements where persisted.isAutoRenewable && persisted.appearsValid() {
                if persisted.subscriptionGroupID == subscriptionGroupID {
                    return true
                }
            }
        }

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
        // Check third-party source
        if let thirdPartyIds = await thirdPartySource?.entitledProductIds(),
           thirdPartyIds.contains(productId) {
            return true
        }
        
        // If transactions haven't loaded yet, use persisted data immediately for faster response
        if cache.lastTransactionsLoadedTime == nil {
            if cache.persistedEntitlements.contains(where: { $0.productID == productId && $0.appearsValid() }) {
                return true
            }
        }
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
        // If transactions haven't loaded yet, use persisted data immediately for faster response
        if cache.lastTransactionsLoadedTime == nil {
            if cache.persistedEntitlements.contains(where: { $0.productID == productId && $0.appearsValid() && $0.isPersonalPurchase }) {
                return true
            }
        }
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
        clearPersistedEntitlements()
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
                    // Persist the updated entitlements
                    saveEntitlements()
                }
            } else {
                cache.lastTransactionsLoadedTime = nil
            }
        }

        cache.subscriptionStatuses[productID] = nil
        let _ = await getSubscriptionStatus(for: productID)

        // Delegate to third-party source if registered
        await thirdPartySource?.didCompletePurchase(productId: productID)
        
        // Check paywalls downloaded to be safer. If non-fallback, paywalls should be downloaded. If fallback, paywalls
        // may or may not be downloaded.
        if Helium.shared.paywallsLoaded() {
            await refreshEntitledForTriggerCache()
        }
    }

    /// Sets up a one-time observer for config download completion
    private func setupConfigDownloadObserver() {
        // Remove any existing observer first
        if let existingObserver = configDownloadObserver {
            NotificationCenter.default.removeObserver(existingObserver)
            configDownloadObserver = nil
        }

        configDownloadObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HeliumConfigDownloadComplete"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.removeConfigDownloadObserver()
                await self.refreshEntitledForTriggerCache()
            }
        }
    }

    /// Removes the config download observer
    private func removeConfigDownloadObserver() {
        if let observer = configDownloadObserver {
            NotificationCenter.default.removeObserver(observer)
            configDownloadObserver = nil
        }
    }

    /// Refreshes the entitledForTrigger cache for all known triggers
    private func refreshEntitledForTriggerCache() async {
        let triggers = HeliumFetchedConfigManager.shared.getFetchedTriggerNames()
        for trigger in triggers {
            // This will compute and cache the entitlement status for each trigger
            let _ = await hasEntitlementForPaywall(trigger: trigger, considerAssociatedSubscriptions: false)
        }
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

