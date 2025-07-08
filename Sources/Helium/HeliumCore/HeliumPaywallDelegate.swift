//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/19/24.
//

import Foundation
import Segment
import StoreKit


public enum HeliumPaywallTransactionStatus {
    case purchased
    case cancelled
    case failed(Error)
    case restored
    case pending
}

public protocol HeliumPaywallDelegate: AnyObject {
    
    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus
    
    func restorePurchases() async -> Bool
    
    func onHeliumPaywallEvent(event: HeliumPaywallEvent)
    
    func getCustomVariableValues() -> [String: Any?]
}

// Extension to provide default implementation
public extension HeliumPaywallDelegate {
    func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        // Default implementation does nothing
    }
    
    func restorePurchases() async -> Bool {
        // Default implementation is a noop
        return false;
    }
    
    func getCustomVariableValues() -> [String: Any?] {
        // Default implementation returns empty dictionary
        return [:];
    }
}

/// A simple HeliumPaywallDelegate implementation that uses StoreKit 2 under the hood.
@available(iOS 15.0, *)
public class StoreKitDelegate: HeliumPaywallDelegate {
    
    private(set) var productMappings: [String: Product] = [:];
    
    public init(productIds: [String]) {
        Task {
            do {
                let fetchedProducts = try await Product.products(for: productIds)
                var mappings: [String: Product] = [:];
                // First create the direct mappings from test product IDs
                for fetchedProduct in fetchedProducts {
                    mappings[fetchedProduct.id] = fetchedProduct;
                }
                productMappings = mappings
            } catch {
                print("[Helium] StoreKitDelegate - error fetching products. \(error)")
            }
        }
    }
    
    public func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        do {
            guard let product: Product = productMappings[productId] else {
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
    
    public func restorePurchases() async -> Bool {
        do {
            try await AppStore.sync()
            return true
        } catch {
            print("[Helium] StoreKitDelegate - Restore purchases was unsuccessful: \(error)")
            return false
        }
    }
    
    public func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        // Override in a subclass if desired
    }
}
public enum StoreKitDelegateError: Error {
    case cannotFindProduct
    case unknownPurchaseResult
    
    var errorDescription: String? {
        switch self {
        case .cannotFindProduct:
            return "Could not find product. Please ensure products are properly configured."
        case .unknownPurchaseResult:
            return "Purchase returned an unknown status."
        }
    }
}


public class HeliumPaywallDelegateWrapper: ObservableObject {
    
    public static let shared = HeliumPaywallDelegateWrapper()
    
    private var delegate: HeliumPaywallDelegate?
    private var analytics: Analytics?
    private var isAnalyticsEnabled: Bool = true
    
    public func setDelegate(_ delegate: HeliumPaywallDelegate) {
        self.delegate = delegate
    }
    
    public func setAnalytics(_ analytics: Analytics) {
        self.analytics = analytics
    }
    
    public func getAnalytics() -> Analytics? {
        return analytics;
    }
    
    public func setIsAnalyticsEnabled(shouldEnable: Bool) {
        isAnalyticsEnabled = shouldEnable;
    }
    
    public func getIsAnalyticsEnabled() -> Bool {
        return isAnalyticsEnabled;
    }
    
    public func getCustomVariableValues() -> [String: Any?] {
        return self.delegate?.getCustomVariableValues() ?? [:];
    }
    
    public func handlePurchase(productKey: String, triggerName: String, paywallTemplateName: String) async -> HeliumPaywallTransactionStatus? {
        let transactionStatus = await delegate?.makePurchase(productId: productKey);
        switch transactionStatus {
        case .cancelled:
            self.onHeliumPaywallEvent(event: .subscriptionCancelled(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName))
        case .failed(let error):
            self.onHeliumPaywallEvent(event: .subscriptionFailed(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName, error: error.localizedDescription))
        case .restored:
            self.onHeliumPaywallEvent(event: .subscriptionRestored(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName))
        case .purchased:
            self.onHeliumPaywallEvent(event: .subscriptionSucceeded(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName))
        case .pending:
            self.onHeliumPaywallEvent(event: .subscriptionPending(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName))
        default:
            break
        }
        return transactionStatus;
    }
    
    public func restorePurchases(triggerName: String, paywallTemplateName: String) async -> Bool {
        if (delegate == nil) {
            return false;
        }
        let result = await delegate!.restorePurchases();
        if (result) {
            self.onHeliumPaywallEvent(event: .subscriptionRestored(productKey: "HELIUM_GENERIC_PRODUCT", triggerName: triggerName, paywallTemplateName: paywallTemplateName))
        } else {
            self.onHeliumPaywallEvent(event: .subscriptionRestoreFailed(triggerName: triggerName, paywallTemplateName: paywallTemplateName))
            await MainActor.run {
               let alert = UIAlertController(
                   title: "Restore Failed",
                   message: "We couldn't find any previous purchases to restore.",
                   preferredStyle: .alert
               )
               
               // Add a single OK button
               alert.addAction(UIAlertAction(
                   title: "OK",
                   style: .default
               ))
               
               // Get the top view controller to present the alert
               if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let topVC = windowScene.windows.first?.rootViewController {
                   var presentedVC = topVC
                   while let presented = presentedVC.presentedViewController {
                       presentedVC = presented
                   }
                   presentedVC.present(alert, animated: true)
               }
           }
        }
        return result;
    }
    
    
    public func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        if case .paywallOpen = event {
            HeliumIdentityManager.shared.setPaywallSessionId()
        } else if case .paywallClose = event {
            HeliumIdentityManager.shared.clearPaywallSessionId()
        }
        
        do {
            delegate?.onHeliumPaywallEvent(event: event);
            if (isAnalyticsEnabled && analytics != nil) {
                var experimentID: String? = nil;
                var modelID: String? = nil;
                var paywallInfo: HeliumPaywallInfo? = nil;
                var isFallback = false;
                if let triggerName = event.getTriggerIfExists() {
                    experimentID = HeliumFetchedConfigManager.shared.getExperimentIDForTrigger(triggerName);
                    modelID = HeliumFetchedConfigManager.shared.getModelIDForTrigger(triggerName);
                    paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(triggerName);
                    if (paywallInfo == nil) {
                        isFallback = true;
                    } else {
                        isFallback = paywallInfo?.paywallTemplateName == "Fallback";
                    }
                }
                
                let fetchedConfigId = HeliumFetchedConfigManager.shared.getConfigId();
                let eventForLogging = HeliumPaywallLoggedEvent(
                    heliumEvent: event,
                    fetchedConfigId: fetchedConfigId,
                    timestamp: formatAsTimestamp(date: Date()),
                    experimentID: experimentID,
                    modelID: modelID,
                    paywallID: paywallInfo?.paywallID,
                    paywallUUID: paywallInfo?.paywallUUID,
                    organizationID: HeliumFetchedConfigManager.shared.getOrganizationID(),
                    heliumPersistentID: HeliumIdentityManager.shared.getHeliumPersistentId(),
                    heliumSessionID: HeliumIdentityManager.shared.getHeliumSessionId(),
                    heliumPaywallSessionId: HeliumIdentityManager.shared.getPaywallSessionId(),
                    revenueCatAppUserID: HeliumIdentityManager.shared.revenueCatAppUserId,
                    isFallback: isFallback,
                    downloadStatus: HeliumFetchedConfigManager.shared.downloadStatus,
                    additionalFields: HeliumFetchedConfigManager.shared.fetchedConfig?.additionalFields,
                    additionalPaywallFields: paywallInfo?.additionalPaywallFields
                );
                
                analytics?.track(name: "helium_" + event.caseString(), properties: eventForLogging);
            }
        } catch {
            print("Delegate action failed.");
        }
    }
    
    public func onFallbackOpenCloseEvent(trigger: String?, isOpen: Bool, viewType: String?) {
        if isOpen {
            onHeliumPaywallEvent(event: .paywallOpen(
                triggerName: trigger ?? HELIUM_FALLBACK_TRIGGER_NAME,
                paywallTemplateName: HELIUM_FALLBACK_PAYWALL_NAME,
                viewType: viewType ?? PaywallOpenViewType.embedded.rawValue
            ))
        } else {
            onHeliumPaywallEvent(event: .paywallClose(
                triggerName: trigger ?? HELIUM_FALLBACK_TRIGGER_NAME,
                paywallTemplateName: HELIUM_FALLBACK_PAYWALL_NAME
            ))
        }
    }
    
}
