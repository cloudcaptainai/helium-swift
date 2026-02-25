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
    
    /// Tracks Transaction.updates observation tasks for pending purchases, keyed by product ID
    @HeliumAtomic private var pendingPurchaseTasks: [String: Task<Void, Never>] = [:]
    
    private var delegate: HeliumPaywallDelegate {
        return Helium.config.purchaseDelegate
    }
    
    func handlePurchase(productKey: String, triggerName: String, paywallTemplateName: String, paywallSession: PaywallSession) async -> HeliumPaywallTransactionStatus? {
        let hadEntitlementBeforePurchase = await withTimeoutOrNil(milliseconds: 500) {
            await HeliumEntitlementsManager.shared.hasPersonallyPurchased(productId: productKey)
        } ?? false
        
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
            var transactionIds: HeliumTransactionIdResult? = nil
            if let transactionDelegate = delegate as? HeliumDelegateReturnsTransaction,
               let heliumTransactionIdResult = transactionDelegate.getLatestCompletedTransactionIdResult() {
                // Double-check to make sure correct transaction retrieved
                if heliumTransactionIdResult.productId == productKey {
                    transactionIds = heliumTransactionIdResult
                }
            }
            if transactionIds == nil {
                transactionIds = await TransactionTools.shared.retrieveTransactionIDs(productId: productKey)
            }
            
            if hadEntitlementBeforePurchase {
                fireEvent(PurchaseAlreadyEntitledEvent(productId: productKey, triggerName: triggerName, paywallName: paywallTemplateName, storeKitTransactionId: transactionIds?.transactionId, storeKitOriginalTransactionId: transactionIds?.originalTransactionId), paywallSession: paywallSession)
            } else {
                syncAfterPurchase(productId: productKey, transaction: transactionIds?.transaction)
                
                #if compiler(>=6.2)
                if let atID = transactionIds?.transaction?.appTransactionID {
                    HeliumIdentityManager.shared.appTransactionID = atID
                }
                #endif
                
                let skPostPurchaseTxnTimeMS = dispatchTimeDifferenceInMS(from: transactionRetrievalStartTime)
                fireEvent(PurchaseSucceededEvent(productId: productKey, triggerName: triggerName, paywallName: paywallTemplateName, storeKitTransactionId: transactionIds?.transactionId, storeKitOriginalTransactionId: transactionIds?.originalTransactionId, skPostPurchaseTxnTimeMS: skPostPurchaseTxnTimeMS), paywallSession: paywallSession)
            }
        case .pending:
            self.fireEvent(PurchasePendingEvent(productId: productKey, triggerName: triggerName, paywallName: paywallTemplateName), paywallSession: paywallSession)
            let detachedSession = paywallSession.withPresentationContext(.empty)
            observePendingPurchase(productId: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName, paywallSession: detachedSession)
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
            if Helium.config.restorePurchasesDialog.showHeliumDialog {
                Task { @MainActor in
                    let alert = UIAlertController(
                        title: Helium.config.restorePurchasesDialog.restoreFailedTitle,
                        message: Helium.config.restorePurchasesDialog.restoreFailedMessage,
                        preferredStyle: .alert
                    )
                    
                    // Add a single OK button
                    alert.addAction(UIAlertAction(
                        title: Helium.config.restorePurchasesDialog.restoreFailedCloseButtonText,
                        style: .default
                    ))
                    
                    let topMostVC = UIWindowHelper.findTopMostViewController()
                    topMostVC?.present(alert, animated: true)
                }
            }
        }
        return result;
    }
    
    private func syncAfterPurchase(productId: String, transaction: Transaction?) {
        Task {
            await HeliumEntitlementsManager.shared.updateAfterPurchase(productID: productId, transaction: transaction)
            
            await HeliumTransactionManager.shared.updateAfterPurchase(transaction: transaction)
            
            // update localized products (and offer eligibility) after purchase
            await HeliumFetchedConfigManager.shared.refreshLocalizedPriceMap()
        }

    }
    
    
    /// Fire a v2 typed event - main entry point for all SDK events
    func fireEvent(
        _ event: HeliumEvent,
        paywallSession: PaywallSession?,
        overridePresentationContext: PaywallPresentationContext? = nil
    ) {
        Task { @MainActor in
            let context = overridePresentationContext ?? paywallSession?.presentationContext
            
            // First, call the event service if configured (from session context)
            context?.eventHandlers?.handleEvent(event)
            
            // Then fire the new typed event to delegate
            delegate.onPaywallEvent(event)
            
            // Global event handlers
            HeliumEventListeners.shared.dispatchEvent(event)
            
            if let openFailEvent = event as? PaywallOpenFailedEvent, !openFailEvent.isSecondTry {
                context?.onPaywallNotShown?(.error(unavailableReason: openFailEvent.paywallUnavailableReason))
            }
        }
        
        var metadata: [String: String] = [:]
        if let productEvent = event as? ProductEvent {
            metadata["productId"] = productEvent.productId
        } else if let paywallEvent = event as? PaywallContextEvent {
            metadata["trigger"] = paywallEvent.triggerName
        }
        HeliumLogger.log(.info, category: .events, "Helium event - \(event.eventName)", metadata: metadata)
        
        if let openFailEvent = event as? PaywallOpenFailedEvent {
            logPaywallUnavailable(
                trigger: openFailEvent.triggerName,
                paywallUnavailableReason: openFailEvent.paywallUnavailableReason,
                logPrefix: "Paywall not shown!", logMetadata: metadata
            )
        }
        if let openEvent = event as? PaywallOpenEvent,
           let paywallUnavailableReason = openEvent.paywallUnavailableReason {
            logPaywallUnavailable(
                trigger: openEvent.triggerName,
                paywallUnavailableReason: paywallUnavailableReason,
                logPrefix: "Fallback paywall shown!", logMetadata: metadata
            )
        }
        if let skipEvent = event as? PaywallSkippedEvent {
            logPaywallSkip(skipReason: skipEvent.skipReason, logMetadata: metadata)
        }
        
        HeliumAnalyticsManager.shared.trackPaywallEvent(event, paywallSession: paywallSession)
        
        // Mark session for onEntitled callback on purchase/restore success
        if let sessionId = paywallSession?.sessionId {
            if event is PurchaseSucceededEvent ||
                event is PurchaseRestoredEvent ||
                event is PurchaseAlreadyEntitledEvent {
                HeliumPaywallPresenter.shared.markSessionAsEntitled(sessionId: sessionId)
            }
        }
    }
    
    private func logPaywallUnavailable(
        trigger: String,
        paywallUnavailableReason: PaywallUnavailableReason?,
        logPrefix: String,
        logMetadata: [String: String]
    ) {
        var notShownAddendum: String = ""
        switch paywallUnavailableReason {
        case .notInitialized:
            notShownAddendum = "Helium is not initialized"
        case .triggerHasNoPaywall:
            notShownAddendum = "Trigger has no paywall. Verify your trigger is in a workflow https://app.tryhelium.com/workflows"
        case .paywallsNotDownloaded, .configFetchInProgress, .bundlesFetchInProgress, .productsFetchInProgress:
            notShownAddendum = "Paywalls have not completed downloading. Check your connection and consider adjusting loading budget or initializing Helium sooner before presenting paywall"
        case .paywallsDownloadFail:
            notShownAddendum = "Paywalls failed to download. Check your connection"
        case .alreadyPresented:
            notShownAddendum = "A Helium paywall is already being presented"
        case .noProductsIOS:
            var paywallLink = "https://app.tryhelium.com/paywalls"
            let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
            if let paywallId = paywallInfo?.paywallUUID {
                paywallLink += "/\(paywallId)"
            }
            notShownAddendum = "Your paywall does not include any iOS products. Ensure you have synced your iOS products and selected products for your paywall \(paywallLink)"
        case .stripeNoCustomUserId:
            notShownAddendum = "Stripe purchase flows require a custom user ID to be set"
        default:
            notShownAddendum = paywallUnavailableReason?.rawValue ?? ""
        }
        HeliumLogger.log(.error, category: .fallback, "\(logPrefix) \(notShownAddendum)", metadata: logMetadata)
    }
    
    private func logPaywallSkip(
        skipReason: PaywallSkippedReason,
        logMetadata: [String: String]
    ) {
        var skipMessage: String = ""
        switch skipReason {
        case .targetingHoldout:
            skipMessage = "Paywall skipped due to targeting holdout"
        case .alreadyEntitled:
            skipMessage = "Paywall not shown because user is already entitled to a product in the paywall. To disable this, ensure dontShowIfAlreadyEntitled is false. https://docs.tryhelium.com/sdk/quickstart-ios#checking-subscription-status-%26-entitlements"
        }
        HeliumLogger.log(.warn, category: .ui, skipMessage, metadata: logMetadata)
    }
    
    // MARK: - Pending Purchase Observation

    /// How long to wait for a pending purchase (e.g., Ask to Buy) before giving up.
    private static let pendingPurchaseTimeoutNanoseconds: UInt64 = 24 * 60 * 60 * 1_000_000_000 // 24 hours

    /// Observes Transaction.updates for a pending purchase (e.g., Ask to Buy) to complete.
    /// When the transaction is approved, finishes it, updates entitlements, and fires events.
    /// Automatically cancels after a timeout if no verified transaction arrives.
    private func observePendingPurchase(productId: String, triggerName: String, paywallTemplateName: String, paywallSession: PaywallSession) {
        let task = Task { [weak self] in
            // Race the transaction listener against a timeout
            await withTaskGroup(of: Void.self) { group in
                // Timeout child task
                group.addTask {
                    try? await Task.sleep(nanoseconds: Self.pendingPurchaseTimeoutNanoseconds)
                    // If we wake up naturally (not cancelled), the timeout has elapsed
                }

                // Transaction listener child task
                group.addTask { [weak self] in
                    for await verificationResult in Transaction.updates {
                        guard !Task.isCancelled else { return }

                        guard case .verified(let transaction) = verificationResult else {
                            continue
                        }
                        guard transaction.productID == productId else {
                            continue
                        }

                        // Revoked transaction (e.g., Ask to Buy declined) — clean up and stop observing
                        if transaction.revocationDate != nil {
                            HeliumLogger.log(.info, category: .core, "Pending purchase revoked for product: \(productId)")
                            self?._pendingPurchaseTasks.withValue { tasks in
                                tasks.removeValue(forKey: productId)
                            }
                            return
                        }

                        HeliumLogger.log(.info, category: .core, "Pending purchase approved for product: \(productId)")

                        // Only finish the transaction if Helium owns StoreKit (StoreKitDelegate);
                        // custom delegates are responsible for finishing transactions themselves.
                        if self?.delegate is StoreKitDelegate {
                            await transaction.finish()
                        }

                        let transactionIds = HeliumTransactionIdResult(transaction: transaction)
                        self?.syncAfterPurchase(productId: productId, transaction: transaction)

                        // Fire purchase success event
                        self?.fireEvent(
                            PurchaseSucceededEvent(
                                productId: productId,
                                triggerName: triggerName,
                                paywallName: paywallTemplateName,
                                storeKitTransactionId: transactionIds.transactionId,
                                storeKitOriginalTransactionId: transactionIds.originalTransactionId,
                                skPostPurchaseTxnTimeMS: nil
                            ),
                            paywallSession: paywallSession
                        )

                        // Clean up this observer
                        self?._pendingPurchaseTasks.withValue { tasks in
                            tasks.removeValue(forKey: productId)
                        }
                        return
                    }
                }

                // Wait for whichever child finishes first (approval, revocation, or timeout),
                // then cancel the other.
                _ = await group.next()
                group.cancelAll()
            }

            // If we got here via timeout, clean up the pending task entry
            self?._pendingPurchaseTasks.withValue { tasks in
                tasks.removeValue(forKey: productId)
            }

            if Task.isCancelled {
                HeliumLogger.log(.info, category: .core, "Pending purchase observer cancelled for product: \(productId)")
            }
        }

        // Cancel any existing observation and store the new one atomically
        _pendingPurchaseTasks.withValue { tasks in
            tasks[productId]?.cancel()
            tasks[productId] = task
        }
    }
}
