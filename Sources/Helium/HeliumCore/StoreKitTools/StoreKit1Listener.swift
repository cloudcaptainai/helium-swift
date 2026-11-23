//
//  StoreKit1Listener.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 9/22/25.
//

import StoreKit

enum StoreKit1TransactionSelection {
    static func latest(
        in transactions: some Sequence<SKPaymentTransaction>,
        productId: String,
        purchasedOnOrAfter: Date? = nil
    ) -> SKPaymentTransaction? {
        transactions.filter {
            guard $0.payment.productIdentifier == productId,
                  $0.transactionState == .purchased else { return false }
            guard let purchasedOnOrAfter else { return true }
            guard let date = $0.transactionDate else { return false }
            return date >= purchasedOnOrAfter
        }.max {
            ($0.transactionDate ?? .distantPast) < ($1.transactionDate ?? .distantPast)
        }
    }
}

private actor StoreKit1TransactionStore {
    // transactionIdentifier -> SKPaymentTransaction
    private var purchaseTransactions: [String: SKPaymentTransaction] = [:]
    
    func addTransaction(_ transaction: SKPaymentTransaction) {
        guard let transactionId = transaction.transactionIdentifier else { return }
        purchaseTransactions[transactionId] = transaction
    }
    
    func getTransactionByProductId(_ productId: String, purchasedOnOrAfter: Date?) -> SKPaymentTransaction? {
        return StoreKit1TransactionSelection.latest(in: purchaseTransactions.values, productId: productId, purchasedOnOrAfter: purchasedOnOrAfter)
    }
}

class StoreKit1Listener : NSObject, SKPaymentTransactionObserver {
    
    static let shared = StoreKit1Listener()
    private let transactionStore = StoreKit1TransactionStore()
    
    override init() {
        super.init()
        SKPaymentQueue.default().add(self)
    }
    
    deinit {
        SKPaymentQueue.default().remove(self)
    }
    
    static func ensureListening() {
        _ = shared
    }
    
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            if transaction.transactionState == .purchased {
                Task {
                    await transactionStore.addTransaction(transaction)
                }
            }
        }
    }
    
    func getSKPaymentTransactionByProductId(_ productId: String, purchasedOnOrAfter: Date? = nil) async -> SKPaymentTransaction? {
        // Check stored transactions first
        if let processed = await transactionStore.getTransactionByProductId(productId, purchasedOnOrAfter: purchasedOnOrAfter) {
            return processed
        }
        
        let pendingTransactions = SKPaymentQueue.default().transactions
        return StoreKit1TransactionSelection.latest(in: pendingTransactions, productId: productId, purchasedOnOrAfter: purchasedOnOrAfter)
    }
    
}
