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

/// Delegate responsible for handling purchases and restores within Helium paywalls.
public protocol HeliumPaywallDelegate: AnyObject {

    /// The delegate type identifier used for SDK analytics.
    var delegateType: String { get }

    /// Execute a purchase for the given product. Return the transaction status.
    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus

    /// Attempt to restore previous purchases. Return `true` if any were restored.
    func restorePurchases() async -> Bool

    /// Optional: called when any paywall-related event occurs.
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

    /// Authored diagnostic copy, shared by the log lines and the diagnostic modal so the two can
    /// never describe the same reason differently.
    private static let diagnosticContentMapper = DiagnosticContentMapper()
    private static let diagnosticLogLineMapper = DiagnosticLogLineMapper()

    /// Tracks Transaction.updates observation tasks for pending purchases, keyed by product ID
    @HeliumAtomic private var pendingPurchaseTasks: [String: Task<Void, Never>] = [:]
    
    private var delegate: HeliumPaywallDelegate {
        return Helium.config.purchaseDelegate
    }
    
    func handlePurchase(productKey: String, triggerName: String, paywallTemplateName: String, paywallSession: PaywallSession) async -> HeliumPaywallTransactionStatus {
        let hadEntitlementBeforePurchase = await withTimeoutOrNil(milliseconds: 500) {
            await HeliumEntitlementsManager.shared.hasPersonallyPurchased(productId: productKey)
        } ?? false
        
        StoreKit1Listener.ensureListening()

        let transactionStatus: HeliumPaywallTransactionStatus

        let paymentProcessor = HeliumPaymentProcessor.resolve(for: productKey)

        if let simulated = await Helium.testing.simulatedPurchaseStatusIfActive(productId: productKey) {
            transactionStatus = simulated
        } else {
            let stripeApplePayFlowEnabled = ApplePayHelper.shared.getStripeApplePayAvailable()

            if paymentProcessor == .stripe && !stripeApplePayFlowEnabled {
                do {
                    let outcome = try await StripeCheckoutManager.shared.startCheckoutFlow(
                        for: productKey,
                        triggerName: triggerName,
                        paywallSession: paywallSession
                    )
                    transactionStatus = outcome.transactionStatus
                } catch {
                    transactionStatus = .failed(error)
                }
            } else if paymentProcessor == .paddle {
                do {
                    let outcome = try await PaddleCheckoutManager.shared.startCheckoutFlow(
                        for: productKey,
                        triggerName: triggerName,
                        paywallSession: paywallSession
                    )
                    transactionStatus = outcome.transactionStatus
                } catch {
                    transactionStatus = .failed(error)
                }
            } else {
                transactionStatus = await delegate.makePurchase(productId: productKey)
            }
        }

        switch transactionStatus {
        case .cancelled:
            self.fireEvent(PurchaseCancelledEvent(productId: productKey, triggerName: triggerName, paywallName: paywallTemplateName, paymentProcessor: paymentProcessor), paywallSession: paywallSession)
        case .failed(let error):
            self.fireEvent(PurchaseFailedEvent(productId: productKey, triggerName: triggerName, paywallName: paywallTemplateName, error: error, paymentProcessor: paymentProcessor), paywallSession: paywallSession)
        case .restored:
            self.fireEvent(PurchaseRestoredEvent(
                productId: productKey,
                triggerName: triggerName,
                paywallName: paywallTemplateName,
                restoreOrigin: .duringPurchase,
                paymentProcessor: paymentProcessor
            ), paywallSession: paywallSession)
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
                let purchaseSucceededEvent = PurchaseSucceededEvent(
                    productId: productKey,
                    triggerName: triggerName,
                    paywallName: paywallTemplateName,
                    storeKitTransactionId: transactionIds?.transactionId,
                    storeKitOriginalTransactionId: transactionIds?.originalTransactionId,
                    skPostPurchaseTxnTimeMS: skPostPurchaseTxnTimeMS,
                    paymentProcessor: paymentProcessor
                )
                fireEvent(purchaseSucceededEvent, paywallSession: paywallSession)
            }
        case .pending:
            self.fireEvent(PurchasePendingEvent(productId: productKey, triggerName: triggerName, paywallName: paywallTemplateName, paymentProcessor: paymentProcessor), paywallSession: paywallSession)
            // Add a listener for pending appStore purchases.
            // Other processors have their own mechanisms for handling pending purchases.
            if paymentProcessor == .appStore {
                let detachedSession = paywallSession.withPresentationContext(.empty)
                observePendingPurchase(productId: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName, paywallSession: detachedSession)
            }
        }
        return transactionStatus;
    }
    
    func restorePurchases(triggerName: String, paywallTemplateName: String, paywallSession: PaywallSession) async -> Bool {
        var result: Bool
        var restoringProcessor: HeliumPaymentProcessor = .appStore

        if let simulated = await Helium.testing.simulatedRestoreResultIfActive() {
            result = simulated
        } else {
            result = await delegate.restorePurchases()

            let processors = Helium.config.webCheckoutProcessors
            if !result && processors.contains(.paddle) {
                await HeliumEntitlementsManager.shared.paddleEntitlementsSource.refreshEntitlements()
                result = await !HeliumEntitlementsManager.shared.paddleEntitlementsSource.purchasedHeliumProductIds().isEmpty
                if result { restoringProcessor = .paddle }
            }
            if !result && processors.contains(.stripe) {
                await HeliumEntitlementsManager.shared.stripeEntitlementsSource.refreshEntitlements()
                result = await !HeliumEntitlementsManager.shared.stripeEntitlementsSource.purchasedHeliumProductIds().isEmpty
                if result { restoringProcessor = .stripe }
            }
        }
        if result {
            self.fireEvent(PurchaseRestoredEvent(productId: "HELIUM_GENERIC_PRODUCT", triggerName: triggerName, paywallName: paywallTemplateName, restoreOrigin: .restorePurchases, paymentProcessor: restoringProcessor), paywallSession: paywallSession)
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
    /// Convenience for firing events when only the paywall session ID is available (e.g. recovery from app termination).
    func fireEvent(
        _ event: HeliumEvent,
        paywallSessionId: String?
    ) {
        fireEvent(event, paywallSession: nil, overridePaywallSessionId: paywallSessionId)
    }

    func fireEvent(
        _ event: HeliumEvent,
        paywallSession: PaywallSession?,
        overridePresentationContext: PaywallPresentationContext? = nil,
        overridePaywallSessionId: String? = nil,
        sendToAnalytics: Bool = true
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
        if let paywallEvent = event as? PaywallContextEvent {
            metadata["trigger"] = paywallEvent.triggerName
        } else if let skipEvent = event as? PaywallSkippedEvent {
            metadata["trigger"] = skipEvent.triggerName
        }
        if let productEvent = event as? ProductEvent {
            metadata["productId"] = productEvent.productId
        }
        if let purchaseFailError = (event as? PurchaseFailedEvent)?.error {
            metadata["error"] = purchaseFailError.localizedDescription
        }
        if paywallSession?.isFallback == true {
            metadata["fallback"] = "true"
        }
        HeliumLogger.log(.info, category: .events, "Helium event - \(event.eventName)", metadata: metadata)
        
        if let openFailEvent = event as? PaywallOpenFailedEvent {
            logPaywallUnavailable(
                trigger: openFailEvent.triggerName,
                paywallUnavailableReason: openFailEvent.paywallUnavailableReason,
                fallbackShown: false, logMetadata: metadata
            )
        }
        if let openEvent = event as? PaywallOpenEvent,
           let paywallUnavailableReason = openEvent.paywallUnavailableReason {
            logPaywallUnavailable(
                trigger: openEvent.triggerName,
                paywallUnavailableReason: paywallUnavailableReason,
                fallbackShown: true, logMetadata: metadata
            )
        }
        if let skipEvent = event as? PaywallSkippedEvent {
            logPaywallSkip(trigger: skipEvent.triggerName, skipReason: skipEvent.skipReason, logMetadata: metadata)
        }
        
        if sendToAnalytics {
            HeliumAnalyticsManager.shared.trackPaywallEvent(event, paywallSession: paywallSession, overridePaywallSessionId: overridePaywallSessionId)
        }
        
        // Mark session for onEntitled callback on purchase/restore success
        if let sessionId = overridePaywallSessionId ?? paywallSession?.sessionId {
            if event is PurchaseSucceededEvent ||
                event is PurchaseRestoredEvent ||
                event is PurchaseAlreadyEntitledEvent {
                HeliumPaywallPresenter.shared.markSessionAsEntitled(sessionId: sessionId)
            }
        }

        if event is PaywallCloseEvent, let paywallSession {
            Task { @MainActor in
                PaddleCheckoutManager.shared.stopObserving(paywallSession: paywallSession)
                StripeCheckoutManager.shared.stopObserving(paywallSession: paywallSession)
                PaddleCheckoutPrefetchCoordinator.shared.handlePaywallClose(paywallSession: paywallSession)
            }
        }

        if event is PaywallOpenEvent, let paywallSession {
            Task { @MainActor in
                PaddleCheckoutPrefetchCoordinator.shared.handlePaywallOpen(paywallSession: paywallSession)
            }
        }
    }
    
    private func logPaywallUnavailable(
        trigger: String,
        paywallUnavailableReason: PaywallUnavailableReason?,
        fallbackShown: Bool,
        logMetadata: [String: String]
    ) {
        let content = Self.diagnosticContentMapper.mapUnavailable(
            paywallUnavailableReason,
            context: .live(trigger: trigger)
        )
        let logPrefix = fallbackShown ? "Fallback paywall shown!" : "Paywall not shown!"
        HeliumLogger.log(
            .error,
            category: .fallback,
            "\(logPrefix) \(Self.diagnosticLogLineMapper.map(content))",
            metadata: logMetadata
        )

        presentDiagnosticIfNeeded(
            trigger: trigger,
            content: content,
            unavailableReason: paywallUnavailableReason,
            fallbackShown: fallbackShown
        )
    }

    private func logPaywallSkip(
        trigger: String,
        skipReason: PaywallSkippedReason,
        logMetadata: [String: String]
    ) {
        let content = Self.diagnosticContentMapper.mapSkip(skipReason)
        HeliumLogger.log(
            .warn,
            category: .ui,
            Self.diagnosticLogLineMapper.map(content),
            metadata: logMetadata
        )

        // A skip is never a suppressed reason, and nothing rendered.
        presentDiagnosticIfNeeded(
            trigger: trigger,
            content: content,
            unavailableReason: nil,
            fallbackShown: false
        )
    }

    /// Single gating funnel for both the unavailable and skip paths, so neither can drift from the
    /// visibility rules.
    private func presentDiagnosticIfNeeded(
        trigger: String,
        content: DiagnosticContent,
        unavailableReason: PaywallUnavailableReason?,
        fallbackShown: Bool
    ) {
        let allowed = HeliumDiagnosticGate.shouldShow(
            unavailableReason: unavailableReason,
            fallbackShown: fallbackShown,
            isPreviewTrigger: trigger == HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER,
            environment: AppReceiptsHelper.shared.environment,
            displayEnabled: Helium.config.paywallNotShownDiagnosticDisplayEnabled,
            enabledInTestFlight: Helium.config.paywallNotShownDiagnosticEnabledInTestFlight,
            serverFlagEnabled: HeliumFetchedConfigManager.shared.fetchedConfig?.diagnosticModalEnabled ?? true,
            doNotShowAgain: {
                UserDefaults.standard.bool(forKey: HeliumDiagnosticGate.doNotShowAgainKey)
            }
        )
        guard allowed else { return }

        Task { @MainActor in
            HeliumPaywallDiagnosticView.presentIfNeeded(trigger: trigger, content: content)
        }
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
