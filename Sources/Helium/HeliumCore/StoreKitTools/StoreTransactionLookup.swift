import StoreKit

struct StoreTransactionSnapshot {
    let ids: HeliumTransactionIdResult
    let purchaseDate: Date
    let isRevoked: Bool
}

/// The store's latest transaction for a product before a purchase attempt; `transactionId` is nil
/// when the store held none.
struct StoreTransactionBaseline {
    let transactionId: String?
}

protocol StoreTransactionLookup {
    func latestTransaction(productId: String) async -> StoreTransactionSnapshot?
}

struct StoreKitTransactionLookup: StoreTransactionLookup {
    func latestTransaction(productId: String) async -> StoreTransactionSnapshot? {
        guard case .verified(let transaction) = await Transaction.latest(for: productId) else {
            return nil
        }
        return StoreTransactionSnapshot(
            ids: HeliumTransactionIdResult(transaction: transaction),
            purchaseDate: transaction.purchaseDate,
            isRevoked: transaction.revocationDate != nil
        )
    }
}

enum StoreCompletedPurchaseCheck {
    /// Device clocks can run ahead of the App Store's, so a transaction made during the
    /// attempt may carry a purchase date slightly before the locally recorded start.
    static let clockSkewTolerance: TimeInterval = 5 * 60

    static func isCompletedDuringAttempt(
        _ latest: StoreTransactionSnapshot?,
        baselineTransactionId: String?,
        attemptStartedAt: Date
    ) -> Bool {
        guard let latest, !latest.isRevoked, let transactionId = latest.ids.transactionId else {
            return false
        }
        if transactionId == baselineTransactionId {
            return false
        }
        return latest.purchaseDate >= attemptStartedAt.addingTimeInterval(-clockSkewTolerance)
    }
}
