//
//  HeliumTransactionManager.swift
//  helium-swift
//

import StoreKit

actor HeliumTransactionManager {
    static let shared = HeliumTransactionManager()
    
    private let syncedTransactionIdsKey = "heliumSyncedTransactionIds"
    private let maxSyncedIdsToStore = 1000
    private let maxTransactionAgeDays = 365 * 2  // 2 years
    
    /// Maps transaction ID to the date it was synced
    private var syncedTransactionIds: [UInt64: Date] = [:]
    private var isConfigured = false
    private let syncClient = TransactionSyncClient()
    private var periodicSyncTask: Task<Void, Never>?
    
    private init() {
        syncedTransactionIds = loadSyncedIds()
    }
    
    // MARK: - Configuration
    
    func configure() async {
        guard !isConfigured else { return }
        isConfigured = true

        startTransactionListener()
        await loadAndSyncTransactionHistory()
        startPeriodicSync()
    }
    
    // Loop through all transactions periodically because Transaction.updates is not guaranteed
    // to run for purchases directly from the app. This is especially important for purchases
    // not made through Helium.
    private func startPeriodicSync() {
        periodicSyncTask = Task {
            while true {
                do {
                    try await Task.sleep(nanoseconds: 1_800_000_000_000) // 30 min
                } catch {
                    break
                }
                await loadAndSyncTransactionHistory()
            }
        }
    }
    
    // MARK: - Transaction Listening

    private func startTransactionListener() {
        Task {
            for await verificationResult in Transaction.updates {
                guard case .verified(let transaction) = verificationResult else {
                    continue
                }
                await processTransaction(transaction)
            }
        }
    }
    
    // Ensure we track a recent purchase
    func updateAfterPurchase(transaction: Transaction?) async {
        guard let transaction else {
            return
        }
        await processTransaction(transaction)
    }
    
    // MARK: - Transaction History
    
    private func loadAndSyncTransactionHistory() async {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxTransactionAgeDays, to: Date()) ?? Date.distantPast
        var transactionsToSync: [Transaction] = []

        for await verificationResult in Transaction.all {
            guard case .verified(let transaction) = verificationResult else {
                continue
            }
            // Skip transactions older than cutoff
            if transaction.purchaseDate < cutoffDate {
                continue
            }
            if syncedTransactionIds[transaction.id] == nil {
                transactionsToSync.append(transaction)
            }
        }

        if !transactionsToSync.isEmpty {
            await syncWithServer(transactions: transactionsToSync)
        }
    }
    
    // MARK: - Processing
    
    private func processTransaction(_ transaction: Transaction) async {
        guard syncedTransactionIds[transaction.id] == nil else {
            return
        }
        await syncWithServer(transactions: [transaction])
    }
    
    // MARK: - Server Sync
    
    private func syncWithServer(transactions: [Transaction]) async {
        syncClient.syncTransactions(transactions)
        
        for transaction in transactions {
            syncedTransactionIds[transaction.id] = transaction.purchaseDate
        }
        pruneAndSave()
    }
    
    // MARK: - Persistence
    
    private func loadSyncedIds() -> [UInt64: Date] {
        guard let data = UserDefaults.standard.data(forKey: syncedTransactionIdsKey),
              let ids = try? JSONDecoder().decode([UInt64: Date].self, from: data) else {
            return [:]
        }
        return ids
    }
    
    private func pruneAndSave() {
        // Remove entries older than maxTransactionAgeDays
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxTransactionAgeDays, to: Date()) ?? Date.distantPast
        syncedTransactionIds = syncedTransactionIds.filter { $0.value >= cutoffDate }

        // If still over limit, keep only the most recent
        if syncedTransactionIds.count > maxSyncedIdsToStore {
            let sorted = syncedTransactionIds.sorted { $0.value > $1.value }
            syncedTransactionIds = Dictionary(uniqueKeysWithValues: sorted.prefix(maxSyncedIdsToStore).map { ($0.key, $0.value) })
        }
        
        guard let data = try? JSONEncoder().encode(syncedTransactionIds) else {
            print("[Helium] Failed to persist synced transaction IDs")
            return
        }
        UserDefaults.standard.set(data, forKey: syncedTransactionIdsKey)
    }

}

// MARK: - Transaction Sync Client

class TransactionSyncClient {
    private let writeKey = "hXu1HzJUX6S3rEZ32C2dRFQOCQBndfiA:ddc16R0zXeNBZWjBXTBh1ybv1sOI8e0N"
    private let endpoint = "cmkc1txw400002e7eyfkbi9rg.d.jitsu.com"
    
    private let analytics: Analytics
    
    init() {
        let configuration = SegmentConfiguration(writeKey: writeKey)
            .apiHost(endpoint)
            .cdnHost(endpoint)
            .trackApplicationLifecycleEvents(false)
        // Using Segment defaults: flushAt=20, flushInterval=30

        analytics = Analytics.getOrCreateAnalytics(configuration: configuration)
    }
    
    func syncTransactions(_ transactions: [Transaction]) {
        guard !transactions.isEmpty else { return }
        
        let heliumPersistentId = HeliumIdentityManager.shared.getHeliumPersistentId()
        let userId = HeliumIdentityManager.shared.getUserId()
        let heliumSessionId = HeliumIdentityManager.shared.getHeliumSessionId()
        // Note that organizationId may not be filled depending on when this is called
        let organizationId = HeliumFetchedConfigManager.shared.getOrganizationID() ?? HeliumFallbackViewManager.shared.getConfig()?.organizationID ?? ""
        let timestamp = formatAsTimestamp(date: Date())
        
        for transaction in transactions {
            if transaction.ownershipType == .familyShared {
                continue // only include purchases by this user
            }
            let rawCountryCode: String
            if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
                rawCountryCode = transaction.storefront.countryCode
            } else {
                rawCountryCode = transaction.storefrontCountryCode
            }
            let storeCountryCode = convertAlpha3ToAlpha2(rawCountryCode) ?? rawCountryCode
            var properties: [String: Any] = [
                "canonicalTransactionId": transaction.id,
                "originalTransactionId": transaction.originalID,
                "heliumPersistentId": heliumPersistentId,
                "userId": userId,
                "heliumSessionId": heliumSessionId,
                "organizationId": organizationId,
                "appBundleId": transaction.appBundleID,
                "productId": transaction.productID,
                "purchasedQuantity": transaction.purchasedQuantity,
                "storeCountryCode": storeCountryCode,
                "purchaseDate": formatAsTimestamp(date: transaction.purchaseDate),
                "platform": "ios",
                "timestamp": timestamp
            ]
            
            if let subscriptionGroupID = transaction.subscriptionGroupID {
                properties["subscriptionGroupId"] = subscriptionGroupID
            }
            
            if #available(iOS 16.0, *) {
                properties["environment"] = transaction.environment.rawValue.uppercased()
            }
            
            if let appAccountToken = transaction.appAccountToken {
                properties["appAttributionToken"] = appAccountToken.uuidString
                properties["appAccountToken"] = appAccountToken.uuidString
            }
            
#if compiler(>=6.2)
            properties["appTransactionId"] = transaction.appTransactionID
            properties["price"] = transaction.price
            if #available(iOS 16.0, *) {
                properties["currency"] = transaction.currency?.identifier ?? ""
            }
#endif
            
            analytics.track(name: "helium_transactionSynced", properties: properties)
        }
        
        analytics.flush()
    }
}
