//
//  TransactionTools.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 9/22/25.
//

import StoreKit

public struct HeliumTransactionIdResult {
    let transactionId: String?
    let originalTransactionId: String?
    let transaction: Transaction?
    let productId: String
    
    public init(transaction: Transaction) {
        transactionId = transaction.id.description
        originalTransactionId = transaction.originalID.description
        self.transaction = transaction
        self.productId = transaction.productID
    }
    
    public init(storeKit1Purchase: SKPaymentTransaction) {
        transactionId = storeKit1Purchase.transactionIdentifier
        originalTransactionId = storeKit1Purchase.original?.transactionIdentifier
        transaction = nil
        productId = storeKit1Purchase.payment.productIdentifier
    }
    
    public init(productId: String, transactionId: String, originalTransactionId: String?) {
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.transaction = nil
        self.productId = productId
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
    
    func retrieveTransactionIDs(productId: String) async -> HeliumTransactionIdResult? {
        // Try StoreKit1 first in case a custom StoreKit1 delegate was used.
        if let storeKit1Purchase = await StoreKit1Listener.shared.getSKPaymentTransactionByProductId(productId) {
            return HeliumTransactionIdResult(storeKit1Purchase: storeKit1Purchase)
        }
        // Yield then try StoreKit1 again
        await Task.yield()
        if let storeKit1Purchase = await StoreKit1Listener.shared.getSKPaymentTransactionByProductId(productId) {
            return HeliumTransactionIdResult(storeKit1Purchase: storeKit1Purchase)
        }
        
        // Then try to look up StoreKit2
        if let transaction = await retrieveTransaction(productId: productId) {
            return HeliumTransactionIdResult(transaction: transaction)
        }
        
        // Check StoreKit1 one more time
        if let storeKit1Purchase = await StoreKit1Listener.shared.getSKPaymentTransactionByProductId(productId) {
            return HeliumTransactionIdResult(storeKit1Purchase: storeKit1Purchase)
        }
        
        return nil
    }
    
}
