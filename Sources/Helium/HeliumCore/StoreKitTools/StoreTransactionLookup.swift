import StoreKit

struct StoreTransactionSnapshot: Sendable {
    let ids: HeliumTransactionIdResult
    let isRevoked: Bool
    /// True for an initial purchase, upgrade or crossgrade; false for a renewal.
    let isPurchaseReason: Bool
    /// False for family-shared access.
    let isOwnedByPurchaser: Bool
}

enum StoreTransactionLookupOutcome: Sendable {
    case noTransaction
    case unverified
    case verified(StoreTransactionSnapshot)
}

/// What the store held for a product before a purchase attempt.
struct StoreTransactionBaseline {
    let state: StoreRecheckBaselineState
    let transactionId: String?
    let durationMs: Int

    /// Only a baseline that read a verified transaction, or confirmed there was none, can tell an
    /// earlier purchase apart from one made during the attempt.
    var isUsable: Bool {
        state == .transactionFound || state == .noTransaction
    }
}

protocol StoreTransactionLookup: Sendable {
    func latestTransaction(productId: String) async -> StoreTransactionLookupOutcome
}

struct StoreKitTransactionLookup: StoreTransactionLookup {
    func latestTransaction(productId: String) async -> StoreTransactionLookupOutcome {
        switch await Transaction.latest(for: productId) {
        case nil:
            return .noTransaction
        case .unverified?:
            return .unverified
        case .verified(let transaction)?:
            return .verified(StoreTransactionSnapshot(
                ids: HeliumTransactionIdResult(transaction: transaction),
                isRevoked: transaction.revocationDate != nil,
                isPurchaseReason: Self.isPurchaseReason(transaction),
                isOwnedByPurchaser: transaction.ownershipType == .purchased
            ))
        }
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
