//
//  StoreKit1Listener.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 9/22/25.
//

import StoreKit

class StoreKit1Listener : NSObject, SKPaymentTransactionObserver {
    
    static let shared = StoreKit1Listener()
    
    private(set) var purchaseTransactions: [SKPaymentTransaction] = []
    
    override init() {
        super.init()
        SKPaymentQueue.default().add(self)
    }
    
    deinit {
        SKPaymentQueue.default().remove(self)
    }
    
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            if transaction.transactionState == .purchased {
                if !purchaseTransactions.contains(where: {
                    $0.transactionIdentifier == transaction.transactionIdentifier
                }) {
                    purchaseTransactions.append(transaction)
                }
            }
        }
    }
    
    func getSKPaymentTransactionByProductId(_ productId: String) -> SKPaymentTransaction? {
        if let processed = purchaseTransactions.first(where: { $0.payment.productIdentifier == productId }) {
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
