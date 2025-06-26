//
//  HeliumRevenueCat.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 6/26/25.
//

import Helium
import RevenueCat

class RevenueCatDelegate: HeliumPaywallDelegate {
    
    let entitlementId: String
    var offerings: Offerings?
        
    public init(entitlementId: String) {
        self.entitlementId = entitlementId
        Task {
            do {
                offerings = try await Purchases.shared.offerings()
            } catch {
                print("[Helium] RevenueCatDelegate - Failed to load RevenueCat offerings: \(error.localizedDescription)")
            }
        }
    }
    
    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
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
    
    func restorePurchases() async -> Bool {
        do {
            _ = try await Purchases.shared.restorePurchases()
            return true
        } catch {
            return false
        }
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
