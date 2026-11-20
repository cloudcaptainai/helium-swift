import Foundation

enum TransactionSyncPolicy {
    static let organizationRetryDelays: [UInt64] = [10, 30, 60].map { $0 * 1_000_000_000 }
    static let schemaVersion = 1
    static let schemaVersionKey = "heliumTransactionSyncSchemaVersion"

    static func migrate(defaults: UserDefaults, syncedIdsKey: String) {
        guard defaults.integer(forKey: schemaVersionKey) < schemaVersion else { return }
        defaults.removeObject(forKey: syncedIdsKey)
        defaults.set(schemaVersion, forKey: schemaVersionKey)
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

    mutating func add(_ transaction: Value, id: UInt64) {
        transactions[id] = transaction
    }

    mutating func remove(ids: [UInt64]) {
        for id in ids { transactions.removeValue(forKey: id) }
    }
}

struct TransactionSyncThrottle {
    private var lastSync: TimeInterval?
    private var hasCompletedScan = false

    mutating func shouldSync(now: TimeInterval, hasPending: Bool = false) -> Bool {
        if !hasPending, let lastSync, now - lastSync < 60 { return false }
        lastSync = now
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
