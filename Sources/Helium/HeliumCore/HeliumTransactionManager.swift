//
//  HeliumTransactionManager.swift
//  helium-swift
//

import StoreKit

actor HeliumTransactionManager {
    static let shared = HeliumTransactionManager()
    
    private let syncedTransactionIdsKey = "heliumSyncedTransactionIds"
    private var syncedTransactionIds: Set<UInt64> = []
    private var updateListenerTask: Task<Void, Never>?
    private var isConfigured = false
    
    private init() {
        syncedTransactionIds = loadSyncedIds()
    }
    
    deinit {
        updateListenerTask?.cancel()
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
        updateListenerTask = Task {
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
        var transactionsToSync: [Transaction] = []

        for await verificationResult in Transaction.all {
            guard case .verified(let transaction) = verificationResult else {
                continue
            }
            if !syncedTransactionIds.contains(transaction.id) {
                transactionsToSync.append(transaction)
            }
        }

        if !transactionsToSync.isEmpty {
            await syncWithServer(transactions: transactionsToSync)
        }
    }
    
    // MARK: - Processing
    
    private func processTransaction(_ transaction: Transaction) async {
        guard !syncedTransactionIds.contains(transaction.id) else {
            return
        }
        await syncWithServer(transactions: [transaction])
    }
    
    // MARK: - Server Sync (placeholder)
    
    private func syncWithServer(transactions: [Transaction]) async {
        // TODO: Implement actual server sync with batching/retries
        // For now, just mark as synced
        for transaction in transactions {
            syncedTransactionIds.insert(transaction.id)
        }
        saveSyncedIds(syncedTransactionIds)
    }
    
    // MARK: - Persistence
    
    private func loadSyncedIds() -> Set<UInt64> {
        guard let data = UserDefaults.standard.data(forKey: syncedTransactionIdsKey),
              let ids = try? JSONDecoder().decode(Set<UInt64>.self, from: data) else {
            return []
        }
        return ids
    }
    
    private func saveSyncedIds(_ ids: Set<UInt64>) {
        guard let data = try? JSONEncoder().encode(ids) else {
            print("[Helium] Failed to persist synced transaction IDs")
            return
        }
        UserDefaults.standard.set(data, forKey: syncedTransactionIdsKey)
    }
    
}
