//
//  StoreKit1Listener.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 9/22/25.
//

import StoreKit

private actor StoreKit1TransactionStore {
    // transactionIdentifier -> SKPaymentTransaction
    private var purchaseTransactions: [String: SKPaymentTransaction] = [:]
    
    func addTransaction(_ transaction: SKPaymentTransaction) {
        guard let transactionId = transaction.transactionIdentifier else { return }
        purchaseTransactions[transactionId] = transaction
    }
    
    func getTransactionByProductId(_ productId: String) -> SKPaymentTransaction? {
        return purchaseTransactions.values.first(where: {
            $0.payment.productIdentifier == productId
        })
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
    
    func getSKPaymentTransactionByProductId(_ productId: String) async -> SKPaymentTransaction? {
        // Check stored transactions first
        if let processed = await transactionStore.getTransactionByProductId(productId) {
            return processed
        }
        
        // Fallback: check what's currently in the queue
        let pendingTransactions = SKPaymentQueue.default().transactions
        return pendingTransactions.first(where: {
            $0.payment.productIdentifier == productId &&
            $0.transactionState == .purchased
        })
    }
    
}
