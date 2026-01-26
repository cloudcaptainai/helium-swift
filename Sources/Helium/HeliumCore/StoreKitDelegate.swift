//
//  StoreKitDelegate.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 9/8/25.
//

import StoreKit

public protocol HeliumDelegateReturnsTransaction {
    func getLatestCompletedTransaction() -> Transaction?
}

/// A simple HeliumPaywallDelegate implementation that uses StoreKit 2 under the hood.
@available(iOS 15.0, *)
open class StoreKitDelegate: HeliumPaywallDelegate, HeliumDelegateReturnsTransaction {
    
    public var delegateType: String { "h_storekit" }
    
    private var latestCompletedTransaction: Transaction? = nil
    
    /// @param productIds  (Optional). A list of product IDs, configured in the App Store, that can be purchased via a Helium paywall. This is not required but may provide a slight performance benefit.
    public init(productIds: [String] = []) {
        guard !productIds.isEmpty else {
            return
        }
        Task {
            // Prefetch products into cache for better performance
            await ProductsCache.shared.prefetchProducts(productIds)
        }
    }
    
    open func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        do {
            guard let product = try await ProductsCache.shared.getProduct(id: productId) else {
                HeliumLogger.log(.error, category: .core, "StoreKitDelegate - makePurchase could not find product: \(productId)")
                return .failed(StoreKitDelegateError.cannotFindProduct)
            }
            
            let result = try await product.heliumPurchase()
                
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    latestCompletedTransaction = transaction
                    await transaction.finish()
                    return .purchased
                case .unverified(_, let error):
                    return .failed(error)
                }
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed(StoreKitDelegateError.unknownPurchaseResult)
            }
        } catch {
            if let storeKitError = error as? StoreKitError,
               case .userCancelled = storeKitError {
                return .cancelled
            }
            HeliumLogger.log(.error, category: .core, "StoreKitDelegate - Purchase failed with error: \(error.localizedDescription)")
            return .failed(error)
        }
    }
    
    open func restorePurchases() async -> Bool {
        return await Helium.entitlements.hasAny()
    }
    
    open func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        // Override in a subclass if desired
    }
    
    open func onPaywallEvent(_ event: HeliumEvent) {
        // Override in a subclass if desired
    }
    
    /// Returns the most recent successful purchase transaction processed by this delegated, if there is one.
    public func getLatestCompletedTransaction() -> Transaction? {
        return latestCompletedTransaction
    }
    
}
public enum StoreKitDelegateError: LocalizedError {
    case cannotFindProduct
    case unknownPurchaseResult
    
    public var errorDescription: String? {
        switch self {
        case .cannotFindProduct:
            return "Could not find product. Please ensure products are properly configured."
        case .unknownPurchaseResult:
            return "Purchase returned an unknown status."
        }
    }
}
