//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/19/24.
//

import Foundation
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
    
    /// Legacy event handler - deprecated in favor of onPaywallEvent
    @available(*, deprecated, message: "Use onPaywallEvent(_:) instead for typed events")
    func onHeliumPaywallEvent(event: HeliumPaywallEvent)
    
    /// Called when any paywall-related event occurs
    /// - Parameter event: The specific event that occurred. Cast to concrete types for access to event-specific properties.
    /// - Note: Common event types include:
    ///   - `PaywallOpenEvent`: Paywall displayed
    ///   - `PurchaseSucceededEvent`: Purchase completed
    ///   - `PurchaseFailedEvent`: Purchase failed
    ///   - `PaywallCloseEvent`: Paywall closed
    /// - Example:
    /// ```swift
    /// func onPaywallEvent(_ event: PaywallEvent) {
    ///     switch event {
    ///     case let openEvent as PaywallOpenEvent:
    ///         print("Paywall opened: \(openEvent.paywallName)")
    ///     case let purchaseEvent as PurchaseSucceededEvent:
    ///         print("Purchased: \(purchaseEvent.productId)")
    ///     default:
    ///         print("Event: \(event.eventName)")
    ///     }
    /// }
    /// ```
    func onPaywallEvent(_ event: PaywallEvent)
    
    func getCustomVariableValues() -> [String: Any?]
}

// Extension to provide default implementation
public extension HeliumPaywallDelegate {
    /// Default implementation for legacy events - does nothing
    func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        // Default implementation does nothing
    }
    
    /// Default implementation for v2 typed events - does nothing
    func onPaywallEvent(_ event: PaywallEvent) {
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
open class StoreKitDelegate: HeliumPaywallDelegate {
    
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
    
    open func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
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


public class HeliumPaywallDelegateWrapper: ObservableObject {
    
    public static let shared = HeliumPaywallDelegateWrapper()
    
    private var delegate: HeliumPaywallDelegate?
    private var analytics: Analytics?
    private var isAnalyticsEnabled: Bool = true
    
    public func setDelegate(_ delegate: HeliumPaywallDelegate) {
        self.delegate = delegate
    }
    
    func setAnalytics(_ analytics: Analytics) {
        self.analytics = analytics
    }
    
    func getAnalytics() -> Analytics? {
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
    
    
    /// Fire a v2 typed event
    public func fireEvent(_ event: PaywallEvent) {
        // First fire the new typed event
        delegate?.onPaywallEvent(event)
        
        // Then convert to legacy format and handle internally (analytics, etc)
        // but skip the delegate call since we already called the new method
        let legacyEvent = event.toLegacyEvent()
        onHeliumPaywallEventInternal(event: legacyEvent, skipDelegateCall: true)
    }
    
    /// Legacy event handler - maintains all existing functionality
    public func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        onHeliumPaywallEventInternal(event: event, skipDelegateCall: false)
    }
    
    /// Internal event handler with option to skip delegate call
    private func onHeliumPaywallEventInternal(event: HeliumPaywallEvent, skipDelegateCall: Bool) {
        let fallbackBundleConfig = HeliumFallbackViewManager.shared.getConfig()
        
        var analyticsForEvent = analytics
        
        if analytics == nil, let fallbackBundleConfig {
            let configuration = SegmentConfiguration(writeKey: fallbackBundleConfig.segmentBrowserWriteKey)
                .apiHost(fallbackBundleConfig.segmentAnalyticsEndpoint)
                .cdnHost(fallbackBundleConfig.segmentAnalyticsEndpoint)
                .trackApplicationLifecycleEvents(false)
                .flushInterval(10)
            analyticsForEvent = Analytics(configuration: configuration)
            analyticsForEvent?.identify(
                userId: HeliumIdentityManager.shared.getUserId(),
                traits: HeliumIdentityManager.shared.getUserContext()
            );
        }
        
        if case .paywallOpen = event {
            HeliumIdentityManager.shared.setPaywallSessionId()
        } else if case .paywallClose = event {
            HeliumIdentityManager.shared.clearPaywallSessionId()
        }
        
        do {
            // Only call the legacy method if not skipped (i.e., when new method wasn't called)
            if !skipDelegateCall {
                delegate?.onHeliumPaywallEvent(event: event);
            }
            if (isAnalyticsEnabled && analyticsForEvent != nil) {
                var experimentID: String? = nil;
                var modelID: String? = nil;
                var paywallInfo: HeliumPaywallInfo? = nil;
                var isFallback = false;
                if let triggerName = event.getTriggerIfExists() {
                    experimentID = HeliumFetchedConfigManager.shared.getExperimentIDForTrigger(triggerName);
                    modelID = HeliumFetchedConfigManager.shared.getModelIDForTrigger(triggerName);
                    paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(triggerName);
                    if paywallInfo == nil {
                        isFallback = true;
                    } else {
                        let eventPaywallTemplateName = event.getPaywallTemplateNameIfExists() ?? ""
                        isFallback = eventPaywallTemplateName == HELIUM_FALLBACK_PAYWALL_NAME || paywallInfo?.paywallTemplateName == HELIUM_FALLBACK_PAYWALL_NAME || eventPaywallTemplateName.starts(with: "fallback_")
                    }
                }
                
                let fetchedConfigId = HeliumFetchedConfigManager.shared.getConfigId() ?? fallbackBundleConfig?.fetchedConfigID
                let eventForLogging = HeliumPaywallLoggedEvent(
                    heliumEvent: event,
                    fetchedConfigId: fetchedConfigId,
                    timestamp: formatAsTimestamp(date: Date()),
                    contextTraits: HeliumIdentityManager.shared.getUserContext(skipDeviceCapacity: true),
                    experimentID: experimentID,
                    modelID: modelID,
                    paywallID: paywallInfo?.paywallID,
                    paywallUUID: paywallInfo?.paywallUUID,
                    organizationID: HeliumFetchedConfigManager.shared.getOrganizationID(),
                    heliumPersistentID: HeliumIdentityManager.shared.getHeliumPersistentId(),
                    heliumSessionID: HeliumIdentityManager.shared.getHeliumSessionId(),
                    heliumPaywallSessionId: HeliumIdentityManager.shared.getPaywallSessionId(),
                    appAttributionToken: HeliumIdentityManager.shared.appAttributionToken.uuidString,
                    revenueCatAppUserID: HeliumIdentityManager.shared.revenueCatAppUserId,
                    isFallback: isFallback,
                    downloadStatus: HeliumFetchedConfigManager.shared.downloadStatus,
                    additionalFields: HeliumFetchedConfigManager.shared.fetchedConfig?.additionalFields,
                    additionalPaywallFields: paywallInfo?.additionalPaywallFields
                );
                
                analyticsForEvent?.track(name: "helium_" + event.caseString(), properties: eventForLogging);
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
