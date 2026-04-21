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
    private let paddlePurchaseSyncDisabled: Bool
    private let _thirdPartyPaymentSyncLock = NSLock()
    private var _isSyncingThirdPartyPayment = false
    private var _thirdPartyPaymentSyncCompleted = false
    private var _hasInvalidatedCache = false
    
    private func configureRevenueCat(revenueCatApiKey: String) {
        if Purchases.isConfigured {
            print("[Helium] RevenueCat has already been configured. Skipping configuration.")
            return
        }
        Purchases.configure(withAPIKey: revenueCatApiKey, appUserID: HeliumIdentityManager.shared.getHeliumPersistentId())
    }
    
    /// Initialize the delegate.
    ///
    /// - Parameter entitlementId: (Optional). The id of the [entitlement](https://www.revenuecat.com/docs/getting-started/entitlements) that you have configured with RevenueCat. If provided, the "restore purchases" action will look for this entitlement otherwise it will look for any active entitlement.
    /// - Parameter productIds: (Optional). A list of product IDs, configured in the App Store, that can be purchased via a Helium paywall. This is not required but may provide a slight performance benefit.
    /// - Parameter revenueCatApiKey: (Optional). Only set if you want Helium to handle RevenueCat initialization for you. Otherwise make sure to [initialize RevenueCat](https://www.revenuecat.com/docs/getting-started/quickstart#initialize-and-configure-the-sdk) before initializing Helium.
    /// - Parameter allowHeliumUserAttribute: (Optional) Allow Helium to set [customer attributes](https://www.revenuecat.com/docs/customers/customer-attributes)
    /// - Parameter stripePurchaseSyncDisabled: (Optional) Set to `true` to disable automatic RevenueCat customer info refresh after a Stripe purchase. Defaults to `false`.
    /// - Parameter paddlePurchaseSyncDisabled: (Optional) Set to `true` to disable automatic RevenueCat customer info refresh after a Paddle purchase. Defaults to `false`.
    public init(
        entitlementId: String? = nil,
        productIds: [String]? = nil,
        revenueCatApiKey: String? = nil,
        allowHeliumUserAttribute: Bool = true,
        stripePurchaseSyncDisabled: Bool = false,
        paddlePurchaseSyncDisabled: Bool = false
    ) {
        self.entitlementId = entitlementId
        self.allowHeliumUserAttribute = allowHeliumUserAttribute
        self.stripePurchaseSyncDisabled = stripePurchaseSyncDisabled
        self.paddlePurchaseSyncDisabled = paddlePurchaseSyncDisabled
        
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
        if let purchaseEvent = event as? PurchaseSucceededEvent,
           shouldSyncAfterThirdPartyPayment(event: purchaseEvent) {
            Task { await syncRevenueCatAfterThirdPartyPayment() }
        }
    }

    // MARK: - Third-Party Payment Sync

    private func shouldSyncAfterThirdPartyPayment(event: PurchaseSucceededEvent) -> Bool {
        switch event.paymentProcessor {
        case .stripe:
            return !stripePurchaseSyncDisabled
        case .paddle:
            return !paddlePurchaseSyncDisabled
        case .appStore:
            return false
        }
    }

    /// After a third-party payment (Stripe or Paddle) completes, the RevenueCat SDK
    /// on-device has no way to know that a new entitlement exists until its backend
    /// processes the provider webhook. This method polls RevenueCat with progressive
    /// backoff to force a customer info refresh, stopping early if the update listener
    /// fires (~50s max).
    private func syncRevenueCatAfterThirdPartyPayment() async {
        // Atomic check-and-set to prevent concurrent syncs
        let alreadySyncing: Bool = _thirdPartyPaymentSyncLock.withLock {
            if _isSyncingThirdPartyPayment { return true }
            _isSyncingThirdPartyPayment = true
            return false
        }
        guard !alreadySyncing else { return }
        defer {
            _thirdPartyPaymentSyncLock.withLock { _isSyncingThirdPartyPayment = false }
        }

        _thirdPartyPaymentSyncLock.withLock {
            _thirdPartyPaymentSyncCompleted = false
            _hasInvalidatedCache = false
        }

        // Listen for customer info updates from RevenueCat in the background.
        // Ignore any emissions that arrive before we've invalidated the cache —
        // customerInfoStream emits the current cached value immediately on subscribe,
        // and we only care about fresh updates triggered by our polling.
        let listenerTask = Task { [weak self] in
            for await _ in Purchases.shared.customerInfoStream {
                guard let self else { return }
                let isRealUpdate = self._thirdPartyPaymentSyncLock.withLock { self._hasInvalidatedCache }
                if isRealUpdate {
                    self._thirdPartyPaymentSyncLock.withLock { self._thirdPartyPaymentSyncCompleted = true }
                    return
                }
            }
        }

        defer { listenerTask.cancel() }

        await pollPhase(attempts: 5, intervalMs: 1_000)
        await pollPhase(attempts: 3, intervalMs: 5_000)
        await pollPhase(attempts: 2, intervalMs: 15_000)
    }

    private var thirdPartyPaymentSyncCompleted: Bool {
        _thirdPartyPaymentSyncLock.withLock { _thirdPartyPaymentSyncCompleted }
    }

    private func pollPhase(attempts: Int, intervalMs: UInt64) async {
        for _ in 0..<attempts {
            if thirdPartyPaymentSyncCompleted { return }
            try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
            if thirdPartyPaymentSyncCompleted { return }
            do {
                _thirdPartyPaymentSyncLock.withLock { _hasInvalidatedCache = true }
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
