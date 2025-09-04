//
//  HeliumRevenueCat.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 6/26/25.
//

import Helium
import RevenueCat
import Foundation

/// A HeliumPaywallDelegate implementation specifically intended for apps that use RevenueCat to handle
/// in-app purchases & subscriptions. Do not use if you don't plan on configuring your purchases with RevenueCat.
open class RevenueCatDelegate: HeliumPaywallDelegate {
    
    public let entitlementId: String?
    private var offerings: Offerings?
    private(set) var productMappings: [String: StoreProduct] = [:]
    
    private func configureRevenueCat(revenueCatApiKey: String) {
        Purchases.configure(withAPIKey: revenueCatApiKey, appUserID: HeliumIdentityManager.shared.getHeliumPersistentId())
    }
    
    /// Initialize the delegate.
    ///
    /// - Parameter entitlementId: (Optional). The id of the [entitlement](https://www.revenuecat.com/docs/getting-started/entitlements) that you have configured with RevenueCat. If provided, the "restore purchases" action will look for this entitlement otherwise it will look for any active entitlement.
    /// - Parameter productIds: (Optional). A list of product IDs, configured in the App Store, that can be purchased via a Helium paywall. This is not required but may provide a slight performance benefit.
    /// - Parameter revenueCatApiKey: (Optional). Only set if you want Helium to handle RevenueCat initialization for you. Otherwise make sure to [initialize RevenueCat](https://www.revenuecat.com/docs/getting-started/quickstart#initialize-and-configure-the-sdk) before initializing Helium.
    public init(
        entitlementId: String? = nil,
        productIds: [String]? = nil,
        revenueCatApiKey: String? = nil
    ) {
        self.entitlementId = entitlementId
        
        if let revenueCatApiKey {
            configureRevenueCat(revenueCatApiKey: revenueCatApiKey)
        }
        
        Task {
            do {
                offerings = try await Purchases.shared.offerings()
                if let productIds {
                    let products = try await Purchases.shared.products(productIds)
                    var mappings: [String: StoreProduct] = [:]
                    // Create product mappings from product IDs
                    for product in products {
                        mappings[product.productIdentifier] = product
                    }
                    productMappings = mappings
                }
            } catch {
                print("[Helium] RevenueCatDelegate - Failed to load RevenueCat offerings/products: \(error.localizedDescription)")
            }
        }
    }
    
    open func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        do {
            var result: PurchaseResultData? = nil
            
            if let offerings {
                var packageToPurchase: Package? = nil
                
                for (_, offering) in offerings.all {
                    for package in offering.availablePackages {
                        if package.storeProduct.productIdentifier == productId {
                            packageToPurchase = package
                            break
                        }
                    }
                    if packageToPurchase != nil {
                        break
                    }
                }
                
                if let package = packageToPurchase {
                    result = try await Purchases.shared.purchase(package: package)
                }
            }
            
            if result == nil {
                if let product = productMappings[productId] {
                    result = try await Purchases.shared.purchase(product: product)
                }
            }
            
            if result == nil {
                let productToPurchase = try await Purchases.shared.products([productId])
                if let product = productToPurchase.first {
                    productMappings[productId] = product
                    result = try await Purchases.shared.purchase(product: product)
                }
            }
            
            guard let result else {
                return .failed(RevenueCatDelegateError.cannotFindProduct)
            }
            
            if result.userCancelled {
                return .cancelled
            }
            
            if isProductActive(customerInfo: result.customerInfo, productId: productId) {
                return .purchased
            } else {
                return .failed(RevenueCatDelegateError.purchaseNotVerified)
            }
        } catch {
            return .failed(error)
        }
    }
    
    open func restorePurchases() async -> Bool {
        do {
            let customerInfo = try await Purchases.shared.restorePurchases()
            if let entitlementId {
                return customerInfo.entitlements[entitlementId]?.isActive == true
            }
            // Just see if any entitlement is active
            return !customerInfo.entitlements.activeInCurrentEnvironment.isEmpty
        } catch {
            return false
        }
    }
    
    open func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        // Override in a subclass if desired
    }
    
    private func isProductActive(customerInfo: CustomerInfo, productId: String) -> Bool {
        if let entitlementId, customerInfo.entitlements[entitlementId]?.isActive == true {
            return true
        }
        if customerInfo.entitlements.activeInCurrentEnvironment.contains(where: { entitlementInfoEntry in
            entitlementInfoEntry.value.productIdentifier == productId
        }) {
            return true
        }
        if customerInfo.activeSubscriptions.contains(where: { productIdentifier in
            productIdentifier == productId
        }) {
            return true
        }
        return false
    }
}

public enum RevenueCatDelegateError: LocalizedError {
    case cannotFindProduct
    case purchaseNotVerified

    public var errorDescription: String? {
        switch self {
        case .cannotFindProduct:
            return "Could not find product. Please ensure products are properly configured."
        case .purchaseNotVerified:
            return "Entitlement could not be verified as active."
        }
    }
}
