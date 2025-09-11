//
//  StoreKitDelegate.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 9/8/25.
//

import StoreKit

/// A simple HeliumPaywallDelegate implementation that uses StoreKit 2 under the hood.
@available(iOS 15.0, *)
open class StoreKitDelegate: HeliumPaywallDelegate {
    
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
                print("[Helium] StoreKitDelegate - makePurchase could not find product!")
                return .failed(StoreKitDelegateError.cannotFindProduct)
            }
            
            let result = try await product.heliumPurchase()
                
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
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
            print("[Helium] StoreKitDelegate - Purchase failed with error: \(error.localizedDescription)")
            return .failed(error)
        }
    }
    
    open func restorePurchases() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified = result {
                return true
            }
        }
        return false
    }
    
    open func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        // Override in a subclass if desired
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
