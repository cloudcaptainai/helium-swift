import Foundation

enum TransactionSyncPolicy {
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

    mutating func shouldSync(now: TimeInterval) -> Bool {
        if let lastSync, now - lastSync < 60 { return false }
        lastSync = now
        return true
    }
}
