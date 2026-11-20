import Foundation

enum TransactionSyncTrigger: String, CaseIterable {
    case listener, history, afterPurchase
}

enum TransactionSyncedIdsState: String, CaseIterable {
    case loaded, empty, migrated, decodeFailed
}

enum TransactionSyncPolicy {
    static func metadata(trigger: TransactionSyncTrigger, sdkEnvironment: String, storeEnvironment: String?,
                         ownershipType: String, revocationDate: Date?, isUpgraded: Bool, expirationDate: Date?,
                         syncedIdCount: Int, syncedIdsState: TransactionSyncedIdsState) -> [String: Any] {
        var properties: [String: Any] = [
            "syncSchemaVersion": 2,
            "syncTrigger": trigger.rawValue,
            "sdkEnvironment": sdkEnvironment,
            "syncedIdCount": syncedIdCount,
            "syncedIdsState": syncedIdsState.rawValue,
            "ownershipType": ownershipType,
            "isUpgraded": isUpgraded
        ]
        if let storeEnvironment { properties["storeEnvironment"] = storeEnvironment }
        if let revocationDate { properties["revocationDate"] = formatAsTimestamp(date: revocationDate) }
        if let expirationDate { properties["expirationDate"] = formatAsTimestamp(date: expirationDate) }
        return properties
    }

    static let organizationRetryDelays: [UInt64] = [10, 30, 60].map { $0 * 1_000_000_000 }
    static let schemaVersion = 1
    static let schemaVersionKey = "heliumTransactionSyncSchemaVersion"

    @discardableResult
    static func migrate(defaults: UserDefaults, syncedIdsKey: String) -> Bool {
        guard defaults.integer(forKey: schemaVersionKey) < schemaVersion else { return false }
        defaults.removeObject(forKey: syncedIdsKey)
        defaults.set(schemaVersion, forKey: schemaVersionKey)
        return true
    }

    static func loadSyncedIds(defaults: UserDefaults, syncedIdsKey: String) -> (ids: [UInt64: Date], state: TransactionSyncedIdsState) {
        if migrate(defaults: defaults, syncedIdsKey: syncedIdsKey) {
            return ([:], .migrated)
        }
        guard let stored = defaults.object(forKey: syncedIdsKey) else { return ([:], .empty) }
        guard let data = stored as? Data,
              let ids = try? JSONDecoder().decode([UInt64: Date].self, from: data) else {
            return ([:], .decodeFailed)
        }
        return (ids, .loaded)
    }

    static func organizationId(_ candidates: String?...) -> String? {
        candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    static func sync(
        transactions: [UInt64: Date],
        organizationId: String?,
        syncedIds: inout [UInt64: Date],
        send: ([UInt64], String) -> Void
    ) {
        guard let organizationId = self.organizationId(organizationId) else { return }
        let unsynced = transactions.filter { syncedIds[$0.key] == nil }
        guard !unsynced.isEmpty else { return }
        send(Array(unsynced.keys), organizationId)
        syncedIds.merge(unsynced) { existing, _ in existing }
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
