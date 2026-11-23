import Foundation
import StoreKit

enum TransactionSyncTrigger: String, CaseIterable {
    case listener, history, afterPurchase
}

enum TransactionSyncedIdsState: String, CaseIterable {
    case loaded, empty, migrated, decodeFailed
}

struct TransactionSyncedIdsFile: Codable {
    let schemaVersion: Int
    let ids: [UInt64: Date]
}

enum TransactionSyncPolicy {
    static func metadata(trigger: TransactionSyncTrigger, sdkEnvironment: String, storeEnvironment: String?,
                         ownershipType: String, revocationDate: Date?, isUpgraded: Bool, expirationDate: Date?,
                         syncedIdCount: Int, syncedIdsState: TransactionSyncedIdsState,
                         productType: Product.ProductType? = nil) -> [String: Any] {
        var properties: [String: Any] = [
            "syncSchemaVersion": 2,
            "syncTrigger": trigger.rawValue,
            "sdkEnvironment": sdkEnvironment,
            "syncedIdCount": syncedIdCount,
            "syncedIdsState": syncedIdsState.rawValue,
            "productType": productType.map(self.productType) ?? "unknown",
            "ownershipType": ownershipType,
            "isUpgraded": isUpgraded
        ]
        if let storeEnvironment { properties["storeEnvironment"] = storeEnvironment }
        if let revocationDate { properties["revocationDate"] = formatAsTimestamp(date: revocationDate) }
        if let expirationDate { properties["expirationDate"] = formatAsTimestamp(date: expirationDate) }
        return properties
    }

    static func productType(_ type: Product.ProductType) -> String {
        switch type {
        case .autoRenewable: return "autoRenewable"
        case .nonRenewable: return "nonRenewable"
        case .consumable: return "consumable"
        case .nonConsumable: return "nonConsumable"
        default: return "unknown"
        }
    }

    static let organizationRetryDelays: [UInt64] = [10, 30, 60].map { $0 * 1_000_000_000 }
    static let schemaVersion = 1
    static func loadSyncedIds(fileURL: URL?, defaults: UserDefaults = .standard) -> (ids: [UInt64: Date], state: TransactionSyncedIdsState) {
        let hadLegacyIds = defaults.object(forKey: "heliumSyncedTransactionIds") != nil
        defaults.removeObject(forKey: "heliumSyncedTransactionIds")
        defaults.removeObject(forKey: "heliumTransactionSyncSchemaVersion")
        guard let fileURL else { return ([:], .decodeFailed) }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return ([:], hadLegacyIds ? .migrated : .empty)
        } catch {
            return ([:], .decodeFailed)
        }
        guard let stored = try? JSONDecoder().decode(TransactionSyncedIdsFile.self, from: data) else {
            return ([:], .decodeFailed)
        }
        if stored.schemaVersion < schemaVersion {
            guard saveSyncedIds([:], fileURL: fileURL) else { return ([:], .decodeFailed) }
            return ([:], .migrated)
        }
        return (stored.ids, .loaded)
    }

    static func saveSyncedIds(_ ids: [UInt64: Date], fileURL: URL?) -> Bool {
        guard let fileURL else { return false }
        do {
            let data = try JSONEncoder().encode(TransactionSyncedIdsFile(schemaVersion: schemaVersion, ids: ids))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func organizationId(_ candidates: String?...) -> String? {
        candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    static func sync(
        transactions: [UInt64: Date],
        organizationId: String?,
        syncedIds: inout [UInt64: Date],
        send: ([UInt64], String) -> [UInt64]
    ) {
        guard let organizationId = self.organizationId(organizationId) else { return }
        let unsynced = transactions.filter { syncedIds[$0.key] == nil }
        guard !unsynced.isEmpty else { return }
        let acceptedIds = Set(send(Array(unsynced.keys), organizationId))
        syncedIds.merge(unsynced.filter { acceptedIds.contains($0.key) }) { existing, _ in existing }
    }
}

struct TransactionHistorySyncState {
    private(set) var isRunning = false
    private var needsRescan = false

    mutating func request() -> Bool {
        guard !isRunning else {
            needsRescan = true
            return false
        }
        isRunning = true
        return true
    }

    mutating func finishPass() -> Bool {
        if needsRescan {
            needsRescan = false
            return true
        }
        isRunning = false
        return false
    }
}

struct TransactionSyncPending<Value> {
    private(set) var transactions: [UInt64: Value] = [:]
    private(set) var triggers: [UInt64: TransactionSyncTrigger] = [:]

    mutating func add(_ transaction: Value, id: UInt64, trigger: TransactionSyncTrigger = .history) {
        transactions[id] = transaction
        if triggers[id] == nil { triggers[id] = trigger }
    }

    mutating func remove(ids: [UInt64]) {
        for id in ids {
            transactions.removeValue(forKey: id)
            triggers.removeValue(forKey: id)
        }
    }
}

struct TransactionSyncThrottle {
    private var lastSync: TimeInterval?
    private var hasCompletedScan = false
    private(set) var deferredForegroundAt: TimeInterval?

    mutating func shouldSync(now: TimeInterval, hasPending: Bool = false) -> Bool {
        if !hasPending, let lastSync, now - lastSync < 60 {
            if deferredForegroundAt == nil { deferredForegroundAt = lastSync + 60 }
            return false
        }
        startedScan()
        lastSync = now
        return true
    }

    mutating func startedScan() {
        deferredForegroundAt = nil
    }

    mutating func takeDeferredForeground(now: TimeInterval) -> Bool {
        guard let deferredForegroundAt, now >= deferredForegroundAt else { return false }
        self.deferredForegroundAt = nil
        return true
    }

    func shouldSyncOnConfig(hasPending: Bool) -> Bool {
        hasPending || !hasCompletedScan
    }

    mutating func completedScan(now: TimeInterval) {
        hasCompletedScan = true
        lastSync = now
    }
}
