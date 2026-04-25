//
//  File.swift
//  
//
//  Created by Anish Doshi on 9/30/24.
//

import Foundation

// Tracks dismiss actions for SwiftUI-presented paywalls (`.triggered` /
// `.embedded`), keyed by `paywallSession.sessionId`. The UIKit-based
// `HeliumPaywallPresenter` handles `.presented` paywalls; this covers the
// gap for paywalls shown via the `.heliumPaywall` modifier or inline
// embedding, which the external web checkout flow needs to close after a
// successful purchase or restore.
@MainActor
private var swiftUIPaywallDismissActions: [String: () -> Void] = [:]

@MainActor
func registerSwiftUIPaywallDismiss(sessionId: String, _ action: @escaping () -> Void) {
    swiftUIPaywallDismissActions[sessionId] = action
}

@MainActor
func unregisterSwiftUIPaywallDismiss(sessionId: String) {
    swiftUIPaywallDismissActions.removeValue(forKey: sessionId)
}

@MainActor
func dismissAllSwiftUIPaywalls() {
    let snapshot = swiftUIPaywallDismissActions
    swiftUIPaywallDismissActions.removeAll()
    for action in snapshot.values { action() }
}

class ActionsDelegateWrapper: ObservableObject {
    let delegate: HeliumActionsDelegate
    
    init(delegate: HeliumActionsDelegate) {
        self.delegate = delegate
    }
    
    func dismiss(dispatchEvent: Bool = true) {
        delegate.dismiss(dispatchEvent: dispatchEvent)
    }
    
    func dismissAll(dispatchEvent: Bool = true) {
        delegate.dismissAll(dispatchEvent: dispatchEvent)
    }
    
    func showSecondaryPaywall(uuid: String?) {
        delegate.showSecondaryPaywall(uuid: uuid)
    }
    
    func onCTAPress(contentComponentName: String) {
        delegate.onCTAPress(contentComponentName: contentComponentName)
    }
    
    func selectProduct(productId: String) {
        delegate.selectProduct(productId: productId)
    }
    
    func logRenderTime(timeTakenMS: UInt64, isFallback: Bool) {
        delegate.logRenderTime(timeTakenMS: timeTakenMS, isFallback: isFallback);
    }
    
    @MainActor
    func makePurchase() async -> HeliumPaywallTransactionStatus {
        await delegate.makePurchase();
    }
    
    @MainActor
    func restorePurchases() async -> Bool {
        await delegate.restorePurchases();
    }
    
    func logImpression(viewType: PaywallOpenViewType, fallbackReason: PaywallUnavailableReason?, loadTimeTakenMS: UInt64? = nil) {
        delegate.logImpression(viewType: viewType, fallbackReason: fallbackReason, loadTimeTakenMS: loadTimeTakenMS)
    }
    
    func logClosure() {
        delegate.logClosure()
    }
    
    func getIsLoading() -> Bool{
        return delegate.getIsLoading();
    }
    
    func onCustomAction(actionName: String, params: [String: Any]) {
        delegate.onCustomAction(actionName: actionName, params: params)
    }
}

class HeliumActionsDelegate: ObservableObject {
    let paywallInfo: HeliumPaywallInfo
    let paywallSession: PaywallSession
    private var selectedProductId: String
    private var isLoading: Bool = false
    private var lastShownSecondTryTrigger: String? = nil
    
    var dismissAction: (() -> Void)?
    
    var trigger: String {
        return paywallSession.trigger
    }
        
    init(paywallInfo: HeliumPaywallInfo, paywallSession: PaywallSession, trigger: String) {
        self.paywallInfo = paywallInfo
        self.paywallSession = paywallSession
        self.selectedProductId = paywallInfo.productIds.first ?? ""
    }
    
    func logRenderTime(timeTakenMS: UInt64, isFallback: Bool) {
        let event = PaywallWebViewRenderedEvent(
            triggerName: trigger,
            paywallName: isFallback ? "fallback_\(paywallInfo.paywallTemplateName)" : paywallInfo.paywallTemplateName,
            webviewRenderTimeTakenMS: timeTakenMS,
            paywallUnavailableReason: isFallback ? .webviewRenderFail : nil
        )
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: paywallSession)
    }
    
    func getIsLoading() -> Bool {
        return isLoading;
    }
    
    func setDismissAction(_ action: @escaping () -> Void) {
        dismissAction = action
    }
    
    func dismiss(dispatchEvent: Bool) {
        HeliumLogger.log(.debug, category: .ui, "Dismiss action triggered", metadata: ["trigger": trigger, "dispatchEvent": String(dispatchEvent)])
        if (!isLoading) {
            if dispatchEvent {
                let event = PaywallDismissedEvent(
                    triggerName: trigger,
                    paywallName: paywallInfo.paywallTemplateName
                )
                HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: paywallSession)
            }
            let dismissed = HeliumPaywallPresenter.shared.hideUpsell() // assumes this paywall is the most recent one shown!
            if !dismissed {
                // otherwise use dismissAction (ex: when paywall presented via DynamicPaywallModifier)
                dismissAction?()
            }
        }
    }
    
    func dismissAll(dispatchEvent: Bool) {
        if (!isLoading) {
            if dispatchEvent {
                let event = PaywallDismissedEvent(
                    triggerName: trigger,
                    paywallName: paywallInfo.paywallTemplateName,
                    dismissAll: true
                )
                HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: paywallSession)
            }
            HeliumPaywallPresenter.shared.hideAllUpsells(onComplete: { [weak self] in
                self?.dismissAction?()
            })
        }
    }
    
    func showSecondaryPaywall(uuid: String?) {
        if !isLoading {
            // Re-use same presentation context as underlying paywall. Integrator can check
            // isSecondTry to distinguish events.
            let presentationContext = paywallSession.presentationContext
            let secondTryTrigger = "\(trigger)_second_try"
            // Try uuid lookup first
            if let uuid, let foundTrigger = HeliumFetchedConfigManager.shared.getTriggerFromPaywallUuid(uuid) {
                lastShownSecondTryTrigger = foundTrigger
                HeliumPaywallPresenter.shared.presentUpsell(trigger: foundTrigger, isSecondTry: true, presentationContext: presentationContext)
            } // Otherwise try second_try trigger
            else if Helium.shared.getPaywallInfo(trigger: secondTryTrigger) != nil {
                lastShownSecondTryTrigger = secondTryTrigger
                HeliumPaywallPresenter.shared.presentUpsell(trigger: secondTryTrigger, isSecondTry: true, presentationContext: presentationContext)
            } else {
                let event = PaywallOpenFailedEvent(
                    triggerName: secondTryTrigger,
                    paywallName: "",
                    error: "Second try - no paywall found for trigger or uuid \(uuid ?? "nil").",
                    paywallUnavailableReason: .secondTryNoMatch,
                    secondTry: true
                )
                HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: nil)
            }
        }
    }
    
    func onCTAPress(contentComponentName: String) {
        if (!isLoading) {
            let event = PaywallButtonPressedEvent(
                buttonName: contentComponentName,
                triggerName: trigger,
                paywallName: paywallInfo.paywallTemplateName
            )
            HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: paywallSession)
        }
    }
    
    func selectProduct(productId: String) {
        selectedProductId = productId
    }
    
    func makePurchase() async -> HeliumPaywallTransactionStatus {
        HeliumLogger.log(.info, category: .core, "makePurchase called", metadata: ["productId": selectedProductId, "trigger": trigger])
        // Use new typed event
        let pressedEvent = PurchasePressedEvent(
            productId: selectedProductId,
            triggerName: trigger,
            paywallName: paywallInfo.paywallTemplateName
        )
        HeliumPaywallDelegateWrapper.shared.fireEvent(pressedEvent, paywallSession: paywallSession)

        isLoading = true
        defer { isLoading = false }
        return await HeliumPaywallDelegateWrapper.shared.handlePurchase(productKey: selectedProductId, triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName, paywallSession: paywallSession)
    }
    
    @MainActor
    func restorePurchases() async -> Bool {
        HeliumLogger.log(.info, category: .core, "restorePurchases called", metadata: ["trigger": trigger])
        isLoading = true;
        let status = await HeliumPaywallDelegateWrapper.shared.restorePurchases(
            triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName, paywallSession: paywallSession
        )
        defer { isLoading = false; }

        HeliumLogger.log(.debug, category: .core, "restorePurchases result", metadata: ["success": String(status)])
        return status;
    }
    
    private var hiddenBehindSecondTry: Bool {
        if let lastShownSecondTryTrigger {
            return HeliumPaywallPresenter.shared.isSecondTryPaywall(trigger: lastShownSecondTryTrigger)
        }
        return false
    }
    
    func logImpression(viewType: PaywallOpenViewType, fallbackReason: PaywallUnavailableReason?, loadTimeTakenMS: UInt64? = nil) {
        if hiddenBehindSecondTry {
            return
        }
        
        // Track experiment allocation for embedded/triggered views
        // Determine if this is a fallback by checking if it's in the fetched config
        let isFallback = fallbackReason != nil
        
        ExperimentAllocationTracker.shared.trackAllocationIfNeeded(
            trigger: trigger,
            isFallback: isFallback,
            paywallSession: paywallSession
        )
        
        let event = PaywallOpenEvent(
            triggerName: trigger,
            paywallName: paywallInfo.paywallTemplateName,
            viewType: viewType,
            loadTimeTakenMS: loadTimeTakenMS,
            loadingBudgetMS: paywallSession.presentationContext.config.loadingBudgetForAnalyticsMS,
            paywallUnavailableReason: fallbackReason
        )
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: paywallSession)
    }
    
    func logClosure() {
        if hiddenBehindSecondTry {
            return
        }
        // Use new typed event
        let event = PaywallCloseEvent(
            triggerName: trigger,
            paywallName: paywallInfo.paywallTemplateName
        )
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: paywallSession)
    }
    
    func onCustomAction(actionName: String, params: [String: Any]) {
        HeliumLogger.log(.debug, category: .ui, "Custom action triggered", metadata: ["actionName": actionName, "trigger": trigger])
        if (!isLoading) {
            let event = CustomPaywallActionEvent(
                actionName: actionName,
                params: params,
                triggerName: trigger,
                paywallName: paywallInfo.paywallTemplateName
            )
            HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: paywallSession)
        }
    }
}
