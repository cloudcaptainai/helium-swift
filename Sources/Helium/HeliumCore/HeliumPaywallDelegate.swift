//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/19/24.
//

import UIKit
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
    func onPaywallEvent(_ event: HeliumEvent)
    
    @available(*, deprecated, message: "Use customPaywallTraits parameter on presentation methods instead")
    func getCustomVariableValues() -> [String: Any?]
}

// Extension to provide default implementation
public extension HeliumPaywallDelegate {
    /// Default implementation for legacy events - does nothing
    func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        // Default implementation does nothing
    }
    
    /// Default implementation for v2 typed events - does nothing
    func onPaywallEvent(_ event: HeliumEvent) {
        // Default implementation does nothing
    }
    
    func restorePurchases() async -> Bool {
        // Default implementation is a noop
        return false;
    }
    
    @available(*, deprecated, message: "Use customPaywallTraits parameter on presentation methods instead")
    func getCustomVariableValues() -> [String: Any?] {
        // Default implementation returns empty dictionary
        return [:];
    }
}


class HeliumPaywallDelegateWrapper {
    
    public static let shared = HeliumPaywallDelegateWrapper()
    static func reset() {
        shared.delegate = nil
        shared.analytics = nil
        shared.eventService = nil
        shared.customPaywallTraits = [:]
        shared.dontShowIfAlreadyEntitled = false
    }
    
    private var delegate: HeliumPaywallDelegate?
    private var analytics: Analytics?
    
    private var eventService: PaywallEventHandlers?
    private var customPaywallTraits: [String: Any] = [:]
    private(set) var dontShowIfAlreadyEntitled: Bool = false
    
    public func setDelegate(_ delegate: HeliumPaywallDelegate) {
        self.delegate = delegate
    }
    
    /// Consolidated method to set both event service and custom traits for a paywall presentation
    public func configurePresentationContext(
        eventService: PaywallEventHandlers?,
        customPaywallTraits: [String: Any]?,
        dontShowIfAlreadyEntitled: Bool = false
    ) {
        // Always set both, even if nil, to ensure proper reset
        self.eventService = eventService
        self.customPaywallTraits = customPaywallTraits ?? [:]
        self.dontShowIfAlreadyEntitled = dontShowIfAlreadyEntitled
    }
    
    /// Clear both event service and custom traits after paywall closes
    private func clearPresentationContext() {
        self.eventService = nil
        self.customPaywallTraits = [:]
        self.dontShowIfAlreadyEntitled = false
    }
    
    func setAnalytics(_ analytics: Analytics) {
        self.analytics = analytics
    }
    
    func getAnalytics() -> Analytics? {
        return analytics;
    }

    public func getCustomVariableValues() -> [String: Any?] {
        if !customPaywallTraits.isEmpty {
            return customPaywallTraits
        }
        // then look at deprecated delegate method
        return delegate?.getCustomVariableValues() ?? [:]
    }
    
    func handlePurchase(productKey: String, triggerName: String, paywallTemplateName: String, paywallSession: PaywallSession) async -> HeliumPaywallTransactionStatus? {
        StoreKit1Listener.ensureListening()
        
        let transactionStatus = await delegate?.makePurchase(productId: productKey);
        switch transactionStatus {
        case .cancelled:
            self.fireEvent(PurchaseCancelledEvent(productId: productKey, triggerName: triggerName, paywallName: paywallTemplateName), paywallSession: paywallSession)
        case .failed(let error):
            self.fireEvent(PurchaseFailedEvent(productId: productKey, triggerName: triggerName, paywallName: paywallTemplateName, error: error), paywallSession: paywallSession)
        case .restored:
            self.fireEvent(PurchaseRestoredEvent(productId: productKey, triggerName: triggerName, paywallName: paywallTemplateName), paywallSession: paywallSession)
        case .purchased:
            let transactionRetrievalStartTime: DispatchTime = DispatchTime.now()
            var transactionIds: TransactionIdPair? = nil
            if let transactionDelegate = delegate as? HeliumDelegateReturnsTransaction,
               let transaction = transactionDelegate.getLatestCompletedTransaction() {
                // Double-check to make sure correct transaction retrieved
                if transaction.productID == productKey {
                    transactionIds = TransactionIdPair(transaction: transaction)
                }
            }
            if transactionIds == nil {
                transactionIds = await TransactionTools.shared.retrieveTransactionIDs(productId: productKey)
            }
            
            Task {
                await HeliumEntitlementsManager.shared.updateAfterPurchase(productID: productKey, transaction: transactionIds?.transaction)
                
                // update localized products (and offer eligibility) after purchase
                await HeliumFetchedConfigManager.shared.refreshLocalizedPriceMap()
            }
            #if compiler(>=6.2)
            if let atID = transactionIds?.transaction?.appTransactionID {
                HeliumIdentityManager.shared.appTransactionID = atID
            }
            #endif
            
            let skPostPurchaseTxnTimeMS = dispatchTimeDifferenceInMS(from: transactionRetrievalStartTime)
            self.fireEvent(PurchaseSucceededEvent(productId: productKey, triggerName: triggerName, paywallName: paywallTemplateName, storeKitTransactionId: transactionIds?.transactionId, storeKitOriginalTransactionId: transactionIds?.originalTransactionId, skPostPurchaseTxnTimeMS: skPostPurchaseTxnTimeMS), paywallSession: paywallSession)
        case .pending:
            self.fireEvent(PurchasePendingEvent(productId: productKey, triggerName: triggerName, paywallName: paywallTemplateName), paywallSession: paywallSession)
        default:
            break
        }
        return transactionStatus;
    }
    
    func restorePurchases(triggerName: String, paywallTemplateName: String, paywallSession: PaywallSession) async -> Bool {
        if (delegate == nil) {
            return false;
        }
        let result = await delegate!.restorePurchases();
        if (result) {
            self.fireEvent(PurchaseRestoredEvent(productId: "HELIUM_GENERIC_PRODUCT", triggerName: triggerName, paywallName: paywallTemplateName), paywallSession: paywallSession)
        } else {
            self.fireEvent(PurchaseRestoreFailedEvent(triggerName: triggerName, paywallName: paywallTemplateName), paywallSession: paywallSession)
            if Helium.restorePurchaseConfig.showHeliumDialog {
                Task { @MainActor in
                    let alert = UIAlertController(
                        title: Helium.restorePurchaseConfig.restoreFailedTitle,
                        message: Helium.restorePurchaseConfig.restoreFailedMessage,
                        preferredStyle: .alert
                    )
                    
                    // Add a single OK button
                    alert.addAction(UIAlertAction(
                        title: Helium.restorePurchaseConfig.restoreFailedCloseButtonText,
                        style: .default
                    ))
                    
                    let topMostVC = UIWindowHelper.findTopMostViewController()
                    topMostVC?.present(alert, animated: true)
                }
            }
        }
        return result;
    }
    
    
    /// Fire a v2 typed event - main entry point for all SDK events
    func fireEvent(_ event: HeliumEvent, paywallSession: PaywallSession?) {
        Task { @MainActor in
            // First, call the event service if configured
            eventService?.handleEvent(event)
            
            // Then fire the new typed event to delegate
            delegate?.onPaywallEvent(event)
            
            // Global event handlers
            HeliumEventListeners.shared.dispatchEvent(event)
            
            // Clear presentation context (event service and custom traits) on close events
            if let closeEvent = event as? PaywallCloseEvent, !closeEvent.isSecondTry {
                clearPresentationContext()
            }
        }
        
        // Then convert to legacy format and handle internally (analytics, etc)
        // AND call the legacy delegate method for backward compatibility
        let legacyEvent = event.toLegacyEvent()
        onHeliumPaywallEvent(event: legacyEvent, paywallSession: paywallSession)
    }
    
    /// Legacy event handler - handles analytics and calls delegate
    public func onHeliumPaywallEvent(event: HeliumPaywallEvent, paywallSession: PaywallSession?) {
        let fallbackBundleConfig = HeliumFallbackViewManager.shared.getConfig()
        
        var analyticsForEvent = analytics
        
        if analytics == nil, let fallbackBundleConfig {
            let neededWriteKey = fallbackBundleConfig.segmentBrowserWriteKey

            // Get or create Analytics instance for the fallback configuration
            let configuration = SegmentConfiguration(writeKey: neededWriteKey)
                .apiHost(fallbackBundleConfig.segmentAnalyticsEndpoint)
                .cdnHost(fallbackBundleConfig.segmentAnalyticsEndpoint)
                .trackApplicationLifecycleEvents(false)
                .flushInterval(10)
            analyticsForEvent = Analytics.getOrCreateAnalytics(configuration: configuration)
            analyticsForEvent?.identify(
                userId: HeliumIdentityManager.shared.getUserId(),
                traits: HeliumIdentityManager.shared.getUserContext()
            );
            // Store this Analytics instance for future use
            if let analyticsForEvent {
                setAnalytics(analyticsForEvent)
            }
        }
        
        do {
            // Call the legacy delegate method for backward compatibility
            delegate?.onHeliumPaywallEvent(event: event);
            if let analyticsForEvent {
                var experimentID: String? = nil;
                var modelID: String? = nil;
                var paywallInfo: HeliumPaywallInfo? = paywallSession?.paywallInfoWithBackups
                var experimentInfo: ExperimentInfo? = nil
                var isFallback: Bool? = nil
                if let paywallSession {
                    isFallback = paywallSession.fallbackType != .notFallback
                }
                if let triggerName = (event.getTriggerIfExists() ?? paywallSession?.trigger) {
                    experimentID = HeliumFetchedConfigManager.shared.getExperimentIDForTrigger(triggerName);
                    modelID = HeliumFetchedConfigManager.shared.getModelIDForTrigger(triggerName);
                    experimentInfo = HeliumFetchedConfigManager.shared.extractExperimentInfo(trigger: triggerName);
                    
                    if paywallInfo == nil && paywallSession == nil {
                        paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(triggerName)
                    }
                    if isFallback == nil {
                        // Old isFallback determination. This can likely be removed at some point.
                        if paywallInfo == nil {
                            isFallback = true
                        } else {
                            let eventPaywallTemplateName = event.getPaywallTemplateNameIfExists() ?? ""
                            isFallback = eventPaywallTemplateName == HELIUM_FALLBACK_PAYWALL_NAME || paywallInfo?.paywallTemplateName == HELIUM_FALLBACK_PAYWALL_NAME || eventPaywallTemplateName.starts(with: "fallback_")
                        }
                    }
                }
                
                let fetchedConfigId = HeliumFetchedConfigManager.shared.getConfigId() ?? fallbackBundleConfig?.fetchedConfigID
                let organizationID = HeliumFetchedConfigManager.shared.getOrganizationID() ?? fallbackBundleConfig?.organizationID
                let eventForLogging = HeliumPaywallLoggedEvent(
                    heliumEvent: event,
                    fetchedConfigId: fetchedConfigId,
                    timestamp: formatAsTimestamp(date: Date()),
                    contextTraits: HeliumIdentityManager.shared.getUserContext(skipDeviceCapacity: true),
                    experimentID: experimentID,
                    modelID: modelID,
                    paywallID: paywallInfo?.paywallID,
                    paywallUUID: paywallInfo?.paywallUUID,
                    organizationID: organizationID,
                    heliumPersistentID: HeliumIdentityManager.shared.getHeliumPersistentId(),
                    heliumSessionID: HeliumIdentityManager.shared.getHeliumSessionId(),
                    heliumInitializeId: HeliumIdentityManager.shared.heliumInitializeId,
                    heliumPaywallSessionId: paywallSession?.sessionId,
                    appAttributionToken: HeliumIdentityManager.shared.appAttributionToken.uuidString,
                    appTransactionId: HeliumIdentityManager.shared.appTransactionID,
                    revenueCatAppUserID: HeliumIdentityManager.shared.revenueCatAppUserId,
                    isFallback: isFallback,
                    downloadStatus: HeliumFetchedConfigManager.shared.downloadStatus,
                    additionalFields: HeliumFetchedConfigManager.shared.fetchedConfig?.additionalFields,
                    additionalPaywallFields: paywallInfo?.additionalPaywallFields,
                    experimentInfo: experimentInfo
                );
                
                analyticsForEvent.track(name: "helium_" + event.caseString(), properties: eventForLogging);
            }
        } catch {
            print("Delegate action failed.");
        }
    }
    
    func onFallbackOpenCloseEvent(trigger: String?, isOpen: Bool, viewType: String?, fallbackReason: PaywallUnavailableReason?, paywallSession: PaywallSession? = nil) {
        if isOpen {
            let viewTypeEnum = PaywallOpenViewType(rawValue: viewType ?? PaywallOpenViewType.embedded.rawValue) ?? .embedded
            fireEvent(PaywallOpenEvent(
                triggerName: trigger ?? HELIUM_FALLBACK_TRIGGER_NAME,
                paywallName: HELIUM_FALLBACK_PAYWALL_NAME,
                viewType: viewTypeEnum,
                paywallUnavailableReason: fallbackReason
            ), paywallSession: paywallSession)
        } else {
            fireEvent(PaywallCloseEvent(
                triggerName: trigger ?? HELIUM_FALLBACK_TRIGGER_NAME,
                paywallName: HELIUM_FALLBACK_PAYWALL_NAME
            ), paywallSession: paywallSession)
        }
    }
    
}
