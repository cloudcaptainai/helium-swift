//
//  TransactionTools.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 9/22/25.
//

import StoreKit

public struct HeliumTransactionIdResult: Sendable {
    let transactionId: String?
    let originalTransactionId: String?
    let transaction: Transaction?
    let productId: String
    let purchaseDate: Date?
    
    public init(transaction: Transaction) {
        transactionId = transaction.id.description
        originalTransactionId = transaction.originalID.description
        self.transaction = transaction
        self.productId = transaction.productID
        purchaseDate = transaction.purchaseDate
    }
    
    public init(storeKit1Purchase: SKPaymentTransaction) {
        transactionId = storeKit1Purchase.transactionIdentifier
        originalTransactionId = storeKit1Purchase.original?.transactionIdentifier
        transaction = nil
        productId = storeKit1Purchase.payment.productIdentifier
        purchaseDate = storeKit1Purchase.transactionDate
    }
    
    public init(productId: String, transactionId: String, originalTransactionId: String?) {
        self.init(productId: productId, transactionId: transactionId, originalTransactionId: originalTransactionId, purchaseDate: nil)
    }

    init(productId: String, transactionId: String, originalTransactionId: String?, purchaseDate: Date?) {
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.transaction = nil
        self.productId = productId
        self.purchaseDate = purchaseDate
    }

    func forPurchase(productId: String, purchasedOnOrAfter: Date) -> Self? {
        guard self.productId == productId,
              let purchaseDate,
              purchaseDate >= purchasedOnOrAfter else {
            return nil
        }
        return self
    }
}

class TransactionTools {
    
    static let shared = TransactionTools()
    
    func retrieveTransaction(productId: String) async -> Transaction? {
        // First try to get directly from product
        if let productVerificationResult = try? await ProductsCache.shared.getProduct(id: productId)?.latestTransaction {
            switch productVerificationResult {
            case .verified(let productTransaction):
                return productTransaction
            default:
                break
            }
        }
        // Backup option - try to get latest transaction directly
        if let verificationResult = await Transaction.latest(for: productId) {
            switch verificationResult {
            case .verified(let productTransaction):
                return productTransaction
            default:
                break
            }
        }
        
        return nil
    }
    
    func retrieveTransactionIDs(productId: String, purchasedOnOrAfter: Date) async -> HeliumTransactionIdResult? {
        // Try StoreKit1 first in case a custom StoreKit1 delegate was used.
        if let storeKit1Purchase = await StoreKit1Listener.shared.getSKPaymentTransactionByProductId(productId),
           let result = HeliumTransactionIdResult(storeKit1Purchase: storeKit1Purchase).forPurchase(productId: productId, purchasedOnOrAfter: purchasedOnOrAfter) {
            return result
        }
        // Yield then try StoreKit1 again
        await Task.yield()
        if let storeKit1Purchase = await StoreKit1Listener.shared.getSKPaymentTransactionByProductId(productId),
           let result = HeliumTransactionIdResult(storeKit1Purchase: storeKit1Purchase).forPurchase(productId: productId, purchasedOnOrAfter: purchasedOnOrAfter) {
            return result
        }
        
        // Then try to look up StoreKit2
        if let transaction = await retrieveTransaction(productId: productId),
           let result = HeliumTransactionIdResult(transaction: transaction).forPurchase(productId: productId, purchasedOnOrAfter: purchasedOnOrAfter) {
            return result
        }
        
        // Check StoreKit1 one more time
        if let storeKit1Purchase = await StoreKit1Listener.shared.getSKPaymentTransactionByProductId(productId),
           let result = HeliumTransactionIdResult(storeKit1Purchase: storeKit1Purchase).forPurchase(productId: productId, purchasedOnOrAfter: purchasedOnOrAfter) {
            return result
        }
        
        return nil
    }
    
}
