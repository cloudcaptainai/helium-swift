//
//  HeliumTransactionManager.swift
//  helium-swift
//

import StoreKit
#if canImport(UIKit)
import UIKit
#endif

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
    private var configDownloadObserver: NSObjectProtocol?
    private var appActiveObserver: NSObjectProtocol?
    private var historySyncState = TransactionHistorySyncState()
    private var foregroundThrottle = TransactionSyncThrottle()
    private var deferredForegroundTask: Task<Void, Never>?
    private var pendingTransactions = TransactionSyncPending<Transaction>()
    private var organizationRetryTask: Task<Void, Never>?
    
    private init() {
        TransactionSyncPolicy.migrate(defaults: .standard, syncedIdsKey: syncedTransactionIdsKey)
        syncedTransactionIds = loadSyncedIds()
    }
    
    // MARK: - Configuration
    
    func configure() async {
        guard !isConfigured else { return }
        isConfigured = true

        configDownloadObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HeliumConfigDownloadComplete"), object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.syncOnConfigDownload() }
        }
#if canImport(UIKit)
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.syncOnForeground() }
        }
#endif
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
                await processTransaction(transaction, trigger: .listener)
            }
        }
    }
    
    // Ensure we track a recent purchase
    func updateAfterPurchase(transaction: Transaction?) async {
        guard let transaction else {
            return
        }
        await processTransaction(transaction, trigger: .afterPurchase)
    }
    
    // MARK: - Transaction History

    private func syncOnForeground() async {
        let hasPending = !pendingTransactions.transactions.isEmpty
        if organizationId != nil {
            guard !historySyncState.isRunning || hasPending else { return }
            guard foregroundThrottle.shouldSync(now: ProcessInfo.processInfo.systemUptime, hasPending: hasPending) else {
                scheduleDeferredForegroundSync()
                return
            }
        }
        await loadAndSyncTransactionHistory()
    }

    private func scheduleDeferredForegroundSync() {
        guard deferredForegroundTask == nil, let deadline = foregroundThrottle.deferredForegroundAt else { return }
        deferredForegroundTask = Task { [weak self] in
            while !Task.isCancelled {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64((remaining * 1_000_000_000).rounded(.up)))
                    } catch {
                        return
                    }
                    continue
                }
                await self?.loadAndSyncTransactionHistory(isDeferredForeground: true)
                return
            }
        }
    }

    private func syncOnConfigDownload() async {
        let hasPending = !pendingTransactions.transactions.isEmpty
        if organizationId != nil {
            guard !historySyncState.isRunning || hasPending else { return }
            guard foregroundThrottle.shouldSyncOnConfig(hasPending: hasPending) else { return }
        }
        await loadAndSyncTransactionHistory()
    }

    private var organizationId: String? {
        TransactionSyncPolicy.organizationId(
            HeliumFetchedConfigManager.shared.getOrganizationID(),
            HeliumFallbackViewManager.shared.getConfig()?.organizationID
        )
    }
    
    @discardableResult
    private func loadAndSyncTransactionHistory(isOrganizationRetry: Bool = false, isDeferredForeground: Bool = false) async -> Bool {
        if isDeferredForeground {
            guard !Task.isCancelled else { return false }
            deferredForegroundTask = nil
            guard foregroundThrottle.takeDeferredForeground(now: ProcessInfo.processInfo.systemUptime) else { return false }
        }
        guard organizationId != nil else {
            scheduleOrganizationRetry()
            return false
        }
        deferredForegroundTask?.cancel()
        deferredForegroundTask = nil
        foregroundThrottle.startedScan()
        guard historySyncState.request() else { return false }
        var didSync = false
        repeat {
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

            transactionsToSync.sort { $0.purchaseDate > $1.purchaseDate }
            if syncWithServer(transactions: Array(transactionsToSync.prefix(maxSyncedIdsToStore))) {
                didSync = true
                foregroundThrottle.completedScan(now: ProcessInfo.processInfo.systemUptime)
                if !isOrganizationRetry {
                    organizationRetryTask?.cancel()
                    organizationRetryTask = nil
                }
            }
        } while historySyncState.finishPass()
        return didSync
    }
    
    // MARK: - Processing
    
    private func processTransaction(_ transaction: Transaction, trigger: TransactionSyncTrigger) async {
        guard syncedTransactionIds[transaction.id] == nil else {
            return
        }
        syncWithServer(transactions: [transaction], trigger: trigger)
    }
    
    // MARK: - Server Sync

    private func scheduleOrganizationRetry() {
        guard organizationRetryTask == nil else { return }
        organizationRetryTask = Task {
            for delay in TransactionSyncPolicy.organizationRetryDelays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                if organizationId != nil {
                    await loadAndSyncTransactionHistory(isOrganizationRetry: true)
                    guard !Task.isCancelled else { return }
                    organizationRetryTask = nil
                    return
                }
            }
            guard !Task.isCancelled else { return }
            organizationRetryTask = nil
        }
    }
    
    @discardableResult
    private func syncWithServer(transactions: [Transaction], trigger: TransactionSyncTrigger = .history) -> Bool {
        for transaction in transactions where syncedTransactionIds[transaction.id] == nil {
            pendingTransactions.add(transaction, id: transaction.id, trigger: trigger)
        }
        guard let organizationId else {
            scheduleOrganizationRetry()
            return false
        }
        let eligible = Array(pendingTransactions.transactions.values)
        let dates = eligible.reduce(into: [UInt64: Date]()) { $0[$1.id] = $1.purchaseDate }
        let client = syncClient
        let triggers = pendingTransactions.triggers
        TransactionSyncPolicy.sync(
            transactions: dates, organizationId: organizationId, syncedIds: &syncedTransactionIds
        ) { ids, organizationId in
            let ids = Set(ids)
            let groups = Dictionary(grouping: eligible.filter { ids.contains($0.id) }) { triggers[$0.id] ?? .history }
            for (trigger, transactions) in groups {
                client.syncTransactions(transactions, organizationId: organizationId, trigger: trigger)
            }
        }
        pendingTransactions.remove(ids: dates.keys.filter { syncedTransactionIds[$0] != nil })
        pruneAndSave()
        return true
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
            HeliumLogger.log(.warn, category: .core, "Failed to persist synced transaction IDs")
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
    
    func syncTransactions(_ transactions: [Transaction], organizationId: String, trigger: TransactionSyncTrigger) {
        guard !transactions.isEmpty, !organizationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        let heliumPersistentId = HeliumIdentityManager.shared.getHeliumPersistentId()
        let userId = HeliumIdentityManager.shared.getResolvedUserId()
        let heliumSessionId = HeliumIdentityManager.shared.getHeliumSessionId()
        let timestamp = formatAsTimestamp(date: Date())
        
        for transaction in transactions {
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
                "platform": HeliumSdkConfig.shared.heliumPlatform,
                "heliumSdkVersion": BuildConstants.version,
                "heliumSdk": HeliumSdkConfig.shared.heliumSdk,
                "heliumWrapperSdkVersion": HeliumSdkConfig.shared.heliumWrapperSdkVersion,
                "timestamp": timestamp
            ]
            
            if let subscriptionGroupID = transaction.subscriptionGroupID {
                properties["subscriptionGroupId"] = subscriptionGroupID
            }
            
            var storeEnvironment: String?
            if #available(iOS 16.0, *) {
                storeEnvironment = transaction.environment.rawValue.uppercased()
                properties["environment"] = transaction.environment.rawValue.uppercased()
            }
            properties.merge(TransactionSyncPolicy.metadata(
                trigger: trigger, sdkEnvironment: AppReceiptsHelper.shared.getEnvironment(),
                storeEnvironment: storeEnvironment,
                ownershipType: transaction.ownershipType == .familyShared ? "FAMILY_SHARED" : transaction.ownershipType.rawValue.uppercased(),
                revocationDate: transaction.revocationDate, isUpgraded: transaction.isUpgraded,
                expirationDate: transaction.expirationDate
            )) { _, value in value }
            
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
