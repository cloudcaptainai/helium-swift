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
    
    public let entitlementId: String
    private var offerings: Offerings?
    private var products: [StoreProduct]?
    
    private func configureRevenueCat(revenueCatApiKey: String) {
        Purchases.configure(withAPIKey: revenueCatApiKey, appUserID: HeliumIdentityManager.shared.getHeliumPersistentId())
    }
    
    /// Initialize the delegate.
    ///
    /// - Parameter entitlementId: The id of the [entitlement](https://www.revenuecat.com/docs/getting-started/entitlements) that you have configured with RevenueCat.
    /// - Parameter revenueCatApiKey: (Optional). Only set if you want Helium to handle RevenueCat initialization for you. Otherwise make sure to [initialize RevenueCat](https://www.revenuecat.com/docs/getting-started/quickstart#initialize-and-configure-the-sdk) before initializing Helium.
    public init(
        entitlementId: String,
        revenueCatApiKey: String? = nil
    ) {
        self.entitlementId = entitlementId
        
        if let revenueCatApiKey {
            configureRevenueCat(revenueCatApiKey: revenueCatApiKey)
        }
        
        Task {
            do {
                offerings = try await Purchases.shared.offerings()
            } catch {
                print("[Helium] RevenueCatDelegate - Failed to load RevenueCat offerings: \(error.localizedDescription)")
            }
        }
    }
    
    /// Initialize the delegate.
    ///
    /// - Parameter entitlementId: The id of the [entitlement](https://www.revenuecat.com/docs/getting-started/entitlements) that you have configured with RevenueCat.
    /// - Parameter productIds: A list of product IDs, configured in the App Store, that can be purchased via a Helium paywall.
    /// - Parameter revenueCatApiKey: (Optional). Only set if you want Helium to handle RevenueCat initialization for you. Otherwise make sure to [initialize RevenueCat](https://www.revenuecat.com/docs/getting-started/quickstart#initialize-and-configure-the-sdk) before initializing Helium.
    public init(
        entitlementId: String,
        productIds: [String],
        revenueCatApiKey: String? = nil
    ) {
        self.entitlementId = entitlementId
        
        if let revenueCatApiKey {
            configureRevenueCat(revenueCatApiKey: revenueCatApiKey)
        }
        
        Task {
            do {
                products = try await Purchases.shared.products(productIds)
            } catch {
                print("[Helium] RevenueCatDelegate - Failed to load RevenueCat products: \(error.localizedDescription)")
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
                
                guard let package = packageToPurchase else {
                    return .failed(RevenueCatDelegateError.cannotFindProductViaOffering)
                }
                
                result = try await Purchases.shared.purchase(package: package)
            }
            
            if let products {
                let productToPurchase = products.first { $0.productIdentifier == productId }
                guard let product = productToPurchase else {
                    return .failed(RevenueCatDelegateError.cannotFindProduct)
                }
                
                result = try await Purchases.shared.purchase(product: product)
            }
            
            guard let result else {
                return .failed(RevenueCatDelegateError.unexpected)
            }
            
            if result.userCancelled {
                return .cancelled
            }
            
            if result.customerInfo.entitlements[entitlementId]?.isActive == true {
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
            return customerInfo.entitlements[entitlementId]?.isActive == true
        } catch {
            return false
        }
    }
    
    open func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        // Override in a subclass if desired
    }
}

public enum RevenueCatDelegateError: LocalizedError {
    case cannotFindProduct
    case cannotFindProductViaOffering
    case purchaseNotVerified
    case unexpected

    public var errorDescription: String? {
        switch self {
        case .cannotFindProduct:
            return "Could not find product. Please ensure products are properly configured."
        case .cannotFindProductViaOffering:
            return "Could not find product. Please ensure offering is properly configured or initialize with productIds instead."
        case .purchaseNotVerified:
            return "Entitlement could not be verified as active."
        case .unexpected:
            return "Unexpected RevenueCatDelegateError."
        }
    }
}
