//
//  HeliumRevenueCat.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 6/26/25.
//

import Helium
import RevenueCat
import Foundation
import StoreKit

/// A HeliumPaywallDelegate implementation specifically intended for apps that use RevenueCat to handle
/// in-app purchases & subscriptions. Do not use if you don't plan on configuring your purchases with RevenueCat.
open class RevenueCatDelegate: HeliumPaywallDelegate, HeliumDelegateReturnsTransaction {
    
    public let entitlementId: String?
    private var offerings: Offerings?
    private(set) var productMappings: [String: StoreProduct] = [:]
    
    private var latestSuccessfulPurchaseResult: PurchaseResultData? = nil
    private var latestSuccessfulPurchaseOffering: Offering? = nil
    
    private let allowHeliumUserAttribute: Bool
    
    private func configureRevenueCat(revenueCatApiKey: String) {
        Purchases.configure(withAPIKey: revenueCatApiKey, appUserID: HeliumIdentityManager.shared.getHeliumPersistentId())
    }
    
    /// Initialize the delegate.
    ///
    /// - Parameter entitlementId: (Optional). The id of the [entitlement](https://www.revenuecat.com/docs/getting-started/entitlements) that you have configured with RevenueCat. If provided, the "restore purchases" action will look for this entitlement otherwise it will look for any active entitlement.
    /// - Parameter productIds: (Optional). A list of product IDs, configured in the App Store, that can be purchased via a Helium paywall. This is not required but may provide a slight performance benefit.
    /// - Parameter revenueCatApiKey: (Optional). Only set if you want Helium to handle RevenueCat initialization for you. Otherwise make sure to [initialize RevenueCat](https://www.revenuecat.com/docs/getting-started/quickstart#initialize-and-configure-the-sdk) before initializing Helium.
    /// - Parameter allowHeliumUserAttribute: (Optional) Allow Helium to set [customer attributes](https://www.revenuecat.com/docs/customers/customer-attributes)
    public init(
        entitlementId: String? = nil,
        productIds: [String]? = nil,
        revenueCatApiKey: String? = nil,
        allowHeliumUserAttribute: Bool = true
    ) {
        self.entitlementId = entitlementId
        self.allowHeliumUserAttribute = allowHeliumUserAttribute
        
        if let revenueCatApiKey {
            configureRevenueCat(revenueCatApiKey: revenueCatApiKey)
        } else if !Purchases.isConfigured {
            print("[Helium] RevenueCatDelegate - RevenueCat has not been configured. You must either configure it before initializing RevenueCatDelegate or pass in revenueCatApiKey to RevenueCatDelegate initializer.") 
        }
        
        // Keep this value as up-to-date as possible
        Helium.shared.setRevenueCatAppUserId(Purchases.shared.appUserID)
        
        if allowHeliumUserAttribute {
            Purchases.shared.attribution.setAttributes([
                "helium_hpid" : HeliumIdentityManager.shared.getHeliumPersistentId()
            ])
        }
        
        Task {
            do {
                offerings = try await Purchases.shared.offerings()
                if let productIds {
                    let products = await Purchases.shared.products(productIds)
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
        // Keep this value as up-to-date as possible
        Helium.shared.setRevenueCatAppUserId(Purchases.shared.appUserID)
        if allowHeliumUserAttribute {
            if let appTransactionID = HeliumIdentityManager.shared.getAppTransactionID() {
                Purchases.shared.attribution.setAttributes([
                    "helium_atid" : appTransactionID,
                ])
            }
        }
        
        do {
            var result: PurchaseResultData? = nil
            var offeringWithProduct: Offering? = nil
            
            if let offerings {
                var packageToPurchase: Package? = nil
                
                for (_, offering) in offerings.all {
                    for package in offering.availablePackages {
                        if package.storeProduct.productIdentifier == productId {
                            packageToPurchase = package
                            offeringWithProduct = offering
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
                let productToPurchase = await Purchases.shared.products([productId])
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
            
            if result.transaction == nil {
                return .failed(RevenueCatDelegateError.couldNotVerifyTransaction)
            }
            
            latestSuccessfulPurchaseResult = result
            latestSuccessfulPurchaseOffering = offeringWithProduct
            
            return .purchased
        } catch {
            if let error = error as? RevenueCat.ErrorCode {
                if error == .paymentPendingError {
                    return .pending
                } else if error == .purchaseCancelledError {
                    return .cancelled
                }
            }
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
    
    open func onPaywallEvent(_ event: HeliumEvent) {
        // Override in a subclass if desired
    }
    
    public func getOfferingWithLatestPurchasedProduct() -> Offering? {
        return latestSuccessfulPurchaseOffering
    }
    public func getLatestCompletedPurchaseResult() -> PurchaseResultData? {
        return latestSuccessfulPurchaseResult
    }
    public func getLatestCompletedTransaction() -> Transaction? {
        return getLatestCompletedPurchaseResult()?.transaction?.sk2Transaction
    }
    
}

public enum RevenueCatDelegateError: LocalizedError {
    case cannotFindProduct
    case couldNotVerifyTransaction

    public var errorDescription: String? {
        switch self {
        case .cannotFindProduct:
            return "Could not find product. Please ensure products are properly configured."
        case .couldNotVerifyTransaction:
            return "Purchase transaction could not be verified."
        }
    }
}
