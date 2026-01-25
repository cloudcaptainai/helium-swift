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
    
    /// The delegate type identifier used for SDK analytics
    var delegateType: String { get }
    
    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus
    
    func restorePurchases() async -> Bool
    
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
}

// Extension to provide default implementation
public extension HeliumPaywallDelegate {
    var delegateType: String { "custom" }

    /// Default implementation for v2 typed events - does nothing
    func onPaywallEvent(_ event: HeliumEvent) {
        // Default implementation does nothing
    }
    
    func restorePurchases() async -> Bool {
        // Default implementation is a noop
        return false;
    }
}


class HeliumPaywallDelegateWrapper {
    
    public static let shared = HeliumPaywallDelegateWrapper()
    static func reset() {
        shared.clearPresentationContext()
    }
    
    private(set) var paywallPresentationConfig: PaywallPresentationConfig? = nil
    private var eventService: PaywallEventHandlers?
    private(set) var onEntitledHandler: (() -> Void)? = nil
    private(set) var onPaywallNotShown: ((PaywallNotShownReason) -> Void)? = nil
    
    private var delegate: HeliumPaywallDelegate {
        return Helium.config.purchaseDelegate
    }
    
    /// Consolidated method to set both event service and custom traits for a paywall presentation
    func configurePresentationContext(
        paywallPresentationConfig: PaywallPresentationConfig,
        eventService: PaywallEventHandlers?,
        onEntitledHandler: (() -> Void)?,
        onPaywallNotShown: @escaping (PaywallNotShownReason) -> Void
    ) {
        // Always set both, even if nil, to ensure proper reset
        self.paywallPresentationConfig = paywallPresentationConfig
        self.eventService = eventService
        self.onEntitledHandler = onEntitledHandler
        self.onPaywallNotShown = onPaywallNotShown
    }
    
    /// Clear both event service and custom traits after paywall closes
    func clearPresentationContext() {
        self.paywallPresentationConfig = nil
        self.eventService = nil
        self.onEntitledHandler = nil
        self.onPaywallNotShown = nil
    }

    public func getCustomVariableValues() -> [String: Any] {
        return paywallPresentationConfig?.customPaywallTraits ?? [:]
    }
    
    func handlePurchase(productKey: String, triggerName: String, paywallTemplateName: String, paywallSession: PaywallSession) async -> HeliumPaywallTransactionStatus? {
        StoreKit1Listener.ensureListening()
        
        let transactionStatus = await delegate.makePurchase(productId: productKey)
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
                
                await HeliumTransactionManager.shared.updateAfterPurchase(transaction: transactionIds?.transaction)
                
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
        let result = await delegate.restorePurchases()
        if result {
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
            delegate.onPaywallEvent(event)
            
            // Global event handlers
            HeliumEventListeners.shared.dispatchEvent(event)
            
            if let openFailEvent = event as? PaywallOpenFailedEvent {
                onPaywallNotShown?(.error(unavailableReason: openFailEvent.paywallUnavailableReason))
            } else if event is PaywallSkippedEvent {
                onPaywallNotShown?(.targetingHoldout)
            }
            
            // Clear presentation context (event service and custom traits) on close events
            if let closeEvent = event as? PaywallCloseEvent, !closeEvent.isSecondTry {
                clearPresentationContext()
            }
        }
        
        HeliumLogger.log(.info, category: .events, "Helium event - \(event.eventName)\nAdd a HeliumEventListener for full event details.")
        
        HeliumAnalyticsManager.shared.trackPaywallEvent(event, paywallSession: paywallSession)
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
