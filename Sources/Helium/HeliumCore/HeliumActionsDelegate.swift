//
//  File.swift
//  
//
//  Created by Anish Doshi on 9/30/24.
//

import Foundation

class ActionsDelegateWrapper: ObservableObject {
    let delegate: HeliumActionsDelegate
    
    init(delegate: HeliumActionsDelegate) {
        self.delegate = delegate
    }
    
    public func dismiss(dispatchEvent: Bool = true) {
        delegate.dismiss(dispatchEvent: dispatchEvent)
    }
    
    public func dismissAll(dispatchEvent: Bool = true) {
        delegate.dismissAll(dispatchEvent: dispatchEvent)
    }
    
    public func showSecondaryPaywall(uuid: String) {
        delegate.showSecondaryPaywall(uuid: uuid)
    }
    
    public func onCTAPress(contentComponentName: String) {
        delegate.onCTAPress(contentComponentName: contentComponentName)
    }
    
    public func showScreen(screenId: String) {
        delegate.showScreen(screenId: screenId)
    }
    
    public func selectProduct(productId: String) {
        delegate.selectProduct(productId: productId)
    }
    
    public func logRenderTime(timeTakenMS: UInt64, isFallback: Bool) {
        delegate.logRenderTime(timeTakenMS: timeTakenMS, isFallback: isFallback);
    }
    
    @MainActor
    public func makePurchase() async -> HeliumPaywallTransactionStatus {
        await delegate.makePurchase();
    }
    
    @MainActor
    public func restorePurchases() async -> Bool {
        await delegate.restorePurchases();
    }
    
    public func logImpression(viewType: PaywallOpenViewType, fallbackReason: PaywallUnavailableReason?) {
        delegate.logImpression(viewType: viewType, fallbackReason: fallbackReason)
    }
    
    public func logClosure() {
        delegate.logClosure()
    }
    
    public func getIsLoading() -> Bool{
        return delegate.getIsLoading();
    }
    
    public func onCustomAction(actionName: String, params: [String: Any]) {
        delegate.onCustomAction(actionName: actionName, params: params)
    }
}

public class HeliumActionsDelegate: ObservableObject {
    let paywallInfo: HeliumPaywallInfo
    let paywallSession: PaywallSession
    @Published var selectedProductId: String
    @Published var isShowingModal: Bool = false
    @Published var showingModalScreen: String? = nil
    private var isLoading: Bool = false
    private var lastShownSecondTryTrigger: String? = nil
    
    var dismissAction: (() -> Void)?
    
    var trigger: String {
        return paywallSession.trigger
    }
        
    init(paywallInfo: HeliumPaywallInfo, paywallSession: PaywallSession, trigger: String) {
        self.paywallInfo = paywallInfo
        self.paywallSession = paywallSession
        self.selectedProductId = "";
        if (!paywallInfo.productsOffered.isEmpty) {
            self.selectedProductId = paywallInfo.productsOffered[0] ?? "";
        }
    }
    
    public func logRenderTime(timeTakenMS: UInt64, isFallback: Bool) {
        let event = PaywallWebViewRenderedEvent(
            triggerName: trigger,
            paywallName: isFallback ? "fallback_\(paywallInfo.paywallTemplateName)" : paywallInfo.paywallTemplateName,
            webviewRenderTimeTakenMS: timeTakenMS,
            paywallUnavailableReason: isFallback ? .webviewRenderFail : nil
        )
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: paywallSession)
    }
    
    public func getIsLoading() -> Bool {
        return isLoading;
    }
    
    func setDismissAction(_ action: @escaping () -> Void) {
        dismissAction = action
    }
    
    public func dismiss(dispatchEvent: Bool) {
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
    
    public func dismissAll(dispatchEvent: Bool) {
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
    
    public func showSecondaryPaywall(uuid: String) {
        if (!isLoading) {
            let secondTryTrigger = "\(trigger)_second_try"
            // use explicit second try trigger if possible
            if Helium.shared.getPaywallInfo(trigger: secondTryTrigger) != nil {
                lastShownSecondTryTrigger = secondTryTrigger
                HeliumPaywallPresenter.shared.presentUpsell(trigger: secondTryTrigger, isSecondTry: true)
            } // otherwise look for a paywall that matches the uuid
            else if let foundTrigger = HeliumFetchedConfigManager.shared.getTriggerFromPaywallUuid(uuid) {
                lastShownSecondTryTrigger = foundTrigger
                HeliumPaywallPresenter.shared.presentUpsell(trigger: foundTrigger, isSecondTry: true)
            } else {
                let event = PaywallOpenFailedEvent(
                    triggerName: secondTryTrigger,
                    paywallName: "",
                    error: "Second try - no paywall found for trigger or uuid \(uuid).",
                    paywallUnavailableReason: .secondTryNoMatch
                )
                HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: nil)
            }
        }
    }
    
    public func onCTAPress(contentComponentName: String) {
        if (!isLoading) {
            let event = PaywallButtonPressedEvent(
                buttonName: contentComponentName,
                triggerName: trigger,
                paywallName: paywallInfo.paywallTemplateName
            )
            HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: paywallSession)
        }
    }
    
    public func showScreen(screenId: String) {
        showingModalScreen = screenId
        isShowingModal = true
    }
    
    public func selectProduct(productId: String) {
        selectedProductId = productId
    }
    
    public func makePurchase() async -> HeliumPaywallTransactionStatus {
        HeliumLogger.log(.info, category: .core, "makePurchase called", metadata: ["productId": selectedProductId, "trigger": trigger])
        // Use new typed event
        let pressedEvent = PurchasePressedEvent(
            productId: selectedProductId,
            triggerName: trigger,
            paywallName: paywallInfo.paywallTemplateName
        )
        HeliumPaywallDelegateWrapper.shared.fireEvent(pressedEvent, paywallSession: paywallSession)

        isLoading = true
        let status = await HeliumPaywallDelegateWrapper.shared.handlePurchase(productKey: selectedProductId, triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName, paywallSession: paywallSession)
        defer { isLoading = false }
        
        if (status == nil) {
            return .failed(NSError(domain: "", code: 401, userInfo: [NSLocalizedDescriptionKey: "Unknown error making purchase - delegate method returned nil"]))
        }
        switch (status) {
            case .none:
                return .failed(NSError(domain: "", code: 401, userInfo: [NSLocalizedDescriptionKey: "Unknown error making purchase - delegate method returned none"]))
            default:
                return status!;
        }
    }
    
    @MainActor
    public func restorePurchases() async -> Bool {
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
    
    public func logImpression(viewType: PaywallOpenViewType, fallbackReason: PaywallUnavailableReason?) {
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
            paywallUnavailableReason: fallbackReason
        )
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: paywallSession)
    }
    
    public func logClosure() {
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
    
    public func onCustomAction(actionName: String, params: [String: Any]) {
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
