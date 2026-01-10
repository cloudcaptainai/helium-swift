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
    
    private init() {
        syncedTransactionIds = loadSyncedIds()
    }
    
    // MARK: - Configuration
    
    func configure() async {
        guard !isConfigured else { return }
        isConfigured = true

        startTransactionListener()
        await loadAndSyncTransactionHistory()
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
    
    // MARK: - Server Sync (placeholder)
    
    private func syncWithServer(transactions: [Transaction]) async {
        // TODO: Implement actual server sync with batching/retries
        // For now, just mark as synced
        let now = Date()
        for transaction in transactions {
            syncedTransactionIds[transaction.id] = now
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
