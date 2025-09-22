//
//  TransactionTools.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 9/22/25.
//

import StoreKit

class TransactionTools {
    
    static let shared = TransactionTools()
    
    func retrieveTransaction(productId: String) async -> Transaction? {
        // Option 1 - try to get directly from product
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
    
}
