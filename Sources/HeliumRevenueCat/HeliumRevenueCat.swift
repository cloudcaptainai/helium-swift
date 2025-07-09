//
//  HeliumRevenueCat.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 6/26/25.
//

import Helium
import RevenueCat

/// A HeliumPaywallDelegate implementation specifically intended for apps that use RevenueCat to handle
/// in-app purchases & subscriptions. Do not use if you don't plan on configuring your purchases with RevenueCat.
public class RevenueCatDelegate: HeliumPaywallDelegate {
    
    let entitlementId: String
    var offerings: Offerings?
    
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
            Purchases.configure(withAPIKey: revenueCatApiKey, appUserID: HeliumIdentityManager.shared.getHeliumPersistentId())
        }
        
        Task {
            do {
                offerings = try await Purchases.shared.offerings()
            } catch {
                print("[Helium] RevenueCatDelegate - Failed to load RevenueCat offerings: \(error.localizedDescription)")
            }
        }
    }
    
    public func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        do {
            guard let offerings = self.offerings else {
                return .failed(RevenueCatDelegateError.couldNotLoadProducts)
            }
            
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
                return .failed(RevenueCatDelegateError.cannotFindProduct)
            }
            
            let result = try await Purchases.shared.purchase(package: package)
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
    
    public func restorePurchases() async -> Bool {
        do {
            let customerInfo = try await Purchases.shared.restorePurchases()
            return customerInfo.entitlements[entitlementId]?.isActive == true
        } catch {
            return false
        }
    }
    
    public func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        // Override in a subclass if desired
    }
}

public enum RevenueCatDelegateError: Error {
    case couldNotLoadProducts
    case cannotFindProduct
    case purchaseNotVerified

    var errorDescription: String? {
        switch self {
        case .couldNotLoadProducts:
            return "Could not load products. Make sure RevenueCat has products configured."
        case .cannotFindProduct:
            return "Could not find product. Please ensure products are properly configured."
        case .purchaseNotVerified:
            return "Entitlement could not be verified as active."
        }
    }
}
