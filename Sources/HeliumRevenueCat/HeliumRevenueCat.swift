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
    
    public var delegateType: String { "h_revenuecat" }
    
    public let entitlementId: String?
    private var offerings: Offerings?
    private(set) var productMappings: [String: StoreProduct] = [:]
    
    private var latestSuccessfulPurchaseResult: PurchaseResultData? = nil
    private var latestSuccessfulPurchaseOffering: Offering? = nil
    
    private let allowHeliumUserAttribute: Bool
    
    private let stripePurchaseSyncDisabled: Bool
    private var isSyncingStripePurchase = false
    
    private func configureRevenueCat(revenueCatApiKey: String) {
        Purchases.configure(withAPIKey: revenueCatApiKey, appUserID: HeliumIdentityManager.shared.getHeliumPersistentId())
    }
    
    /// Initialize the delegate.
    ///
    /// - Parameter entitlementId: (Optional). The id of the [entitlement](https://www.revenuecat.com/docs/getting-started/entitlements) that you have configured with RevenueCat. If provided, the "restore purchases" action will look for this entitlement otherwise it will look for any active entitlement.
    /// - Parameter productIds: (Optional). A list of product IDs, configured in the App Store, that can be purchased via a Helium paywall. This is not required but may provide a slight performance benefit.
    /// - Parameter revenueCatApiKey: (Optional). Only set if you want Helium to handle RevenueCat initialization for you. Otherwise make sure to [initialize RevenueCat](https://www.revenuecat.com/docs/getting-started/quickstart#initialize-and-configure-the-sdk) before initializing Helium.
    /// - Parameter allowHeliumUserAttribute: (Optional) Allow Helium to set [customer attributes](https://www.revenuecat.com/docs/customers/customer-attributes)
    /// - Parameter stripePurchaseSyncDisabled: (Optional) Set to `true` to disable automatic RevenueCat customer info refresh after a Stripe purchase. Defaults to `false`.
    public init(
        entitlementId: String? = nil,
        productIds: [String]? = nil,
        revenueCatApiKey: String? = nil,
        allowHeliumUserAttribute: Bool = true,
        stripePurchaseSyncDisabled: Bool = false
    ) {
        self.entitlementId = entitlementId
        self.allowHeliumUserAttribute = allowHeliumUserAttribute
        self.stripePurchaseSyncDisabled = stripePurchaseSyncDisabled
        
        if let revenueCatApiKey {
            configureRevenueCat(revenueCatApiKey: revenueCatApiKey)
        } else if !Purchases.isConfigured {
            print("[Helium] RevenueCatDelegate - RevenueCat has not been configured. You must either configure it before initializing RevenueCatDelegate or pass in revenueCatApiKey to RevenueCatDelegate initializer.") 
        }
        
        // Keep this value as up-to-date as possible
        Helium.identify.revenueCatAppUserId = Purchases.shared.appUserID
        
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
        Helium.identify.revenueCatAppUserId = Purchases.shared.appUserID
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
    
    /// Subclasses that override this method should call `super.onPaywallEvent(event)`
    /// to preserve built-in post-purchase sync behavior.
    open func onPaywallEvent(_ event: HeliumEvent) {
        if !stripePurchaseSyncDisabled,
           let purchaseEvent = event as? PurchaseSucceededEvent,
           isStripePurchase(event: purchaseEvent) {
            Task { await syncRevenueCatAfterStripePurchase() }
        }
    }
    
    // MARK: - Stripe Purchase Sync
    
    private func isStripePurchase(event: PurchaseSucceededEvent) -> Bool {
        if let txnId = event.storeKitTransactionId, txnId.hasPrefix("si_") {
            return true
        }
        let stripeProductPattern = #"^prod_\w+:price_\w+$"#
        if event.productId.range(of: stripeProductPattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }
    
    /// After a Stripe purchase completes, the RevenueCat SDK on-device has no way to
    /// know that a new entitlement exists until its backend processes the Stripe webhook.
    /// This method polls RevenueCat with progressive backoff to force a customer info
    /// refresh, stopping early if the update listener fires (~50s max).
    private func syncRevenueCatAfterStripePurchase() async {
        guard !isSyncingStripePurchase else { return }
        isSyncingStripePurchase = true
        defer { isSyncingStripePurchase = false }

        var synced = false

        // Listen for customer info updates from RevenueCat in the background
        let listenerTask = Task {
            for await _ in Purchases.shared.customerInfoStream {
                synced = true
                return
            }
        }

        defer { listenerTask.cancel() }

        await pollPhase(attempts: 5, intervalSeconds: 1, synced: &synced)
        await pollPhase(attempts: 3, intervalSeconds: 5, synced: &synced)
        await pollPhase(attempts: 2, intervalSeconds: 15, synced: &synced)
    }
    
    private func pollPhase(attempts: Int, intervalSeconds: UInt64, synced: inout Bool) async {
        for _ in 0..<attempts {
            if synced { return }
            try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            if synced { return }
            do {
                Purchases.shared.invalidateCustomerInfoCache()
                _ = try await Purchases.shared.customerInfo(fetchPolicy: .fetchCurrent)
            } catch {
                // Ignore transient errors (e.g. network failures)
            }
        }
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
    public func getLatestCompletedTransactionIdResult() -> HeliumTransactionIdResult? {
        guard let latestCompletedTransaction = getLatestCompletedTransaction() else {
            return nil
        }
        return HeliumTransactionIdResult(transaction: latestCompletedTransaction)
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
