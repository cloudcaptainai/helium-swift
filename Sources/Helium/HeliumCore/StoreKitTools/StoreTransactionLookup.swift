import StoreKit

struct StoreTransactionSnapshot: Sendable {
    let ids: HeliumTransactionIdResult
    let isRevoked: Bool
    /// True for an initial purchase, upgrade or crossgrade; false for a renewal.
    let isPurchaseReason: Bool
    /// False for family-shared access.
    let isOwnedByPurchaser: Bool
}

/// The store's latest transaction for a product before a purchase attempt; `transactionId` is nil
/// when the store held none.
struct StoreTransactionBaseline: Sendable {
    let transactionId: String?
}

struct StoreTransactionBaselineLookup {
    /// Nil when the lookup did not finish in time.
    let baseline: StoreTransactionBaseline?
    let durationMs: Int
}

/// Distinguishes "the store has no transaction" from a lookup that did not finish.
struct StoreTransactionLookupResult: Sendable {
    let snapshot: StoreTransactionSnapshot?
}

protocol StoreTransactionLookup: Sendable {
    func latestTransaction(productId: String) async -> StoreTransactionSnapshot?
}

struct StoreKitTransactionLookup: StoreTransactionLookup {
    func latestTransaction(productId: String) async -> StoreTransactionSnapshot? {
        guard case .verified(let transaction) = await Transaction.latest(for: productId) else {
            return nil
        }
        return StoreTransactionSnapshot(
            ids: HeliumTransactionIdResult(transaction: transaction),
            isRevoked: transaction.revocationDate != nil,
            isPurchaseReason: Self.isPurchaseReason(transaction),
            isOwnedByPurchaser: transaction.ownershipType == .purchased
        )
    }

    private static func isPurchaseReason(_ transaction: Transaction) -> Bool {
        if #available(iOS 17.0, *) {
            return transaction.reason == .purchase
        }
        return transaction.reasonStringRepresentation.lowercased() == "purchase"
    }
}

enum StoreCompletedPurchaseCheck {
    /// A transaction ID differing from a baseline taken before the attempt means the transaction is
    /// new; requiring a purchase reason keeps a renewal that lands during the attempt from counting.
    static func isCompletedDuringAttempt(
        _ latest: StoreTransactionSnapshot?,
        baselineTransactionId: String?
    ) -> Bool {
        guard let latest,
              !latest.isRevoked,
              latest.isPurchaseReason,
              latest.isOwnedByPurchaser,
              let transactionId = latest.ids.transactionId else {
            return false
        }
        return transactionId != baselineTransactionId
    }
}
