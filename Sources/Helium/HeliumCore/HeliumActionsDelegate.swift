//
//  File.swift
//  
//
//  Created by Anish Doshi on 9/30/24.
//

import Foundation

public protocol BaseActionsDelegate {
    func dismiss(dispatchEvent: Bool);
    func dismissAll(dispatchEvent: Bool);
    func showSecondaryPaywall(uuid: String);
    func onCTAPress(contentComponentName: String);
    func showScreen(screenId: String);
    func selectProduct(productId: String);
    func makePurchase() async -> HeliumPaywallTransactionStatus;
    func restorePurchases() async -> Bool;
    func logImpression(viewType: PaywallOpenViewType, fallbackReason: PaywallUnavailableReason?);
    func logClosure();
    func getIsLoading() -> Bool;
    func logRenderTime(timeTakenMS: UInt64, isFallback: Bool);
    func onCustomAction(actionName: String, params: [String: Any]);
}

public class ActionsDelegateWrapper: ObservableObject {
    private let delegate: BaseActionsDelegate
    
    public init(delegate: BaseActionsDelegate) {
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

public class HeliumActionsDelegate: BaseActionsDelegate, ObservableObject {
    let paywallInfo: HeliumPaywallInfo
    let trigger: String
    @Published var selectedProductId: String
    @Published var isShowingModal: Bool = false
    @Published var showingModalScreen: String? = nil
    private var isLoading: Bool = false
    private var lastShownSecondTryTrigger: String? = nil
    
    var dismissAction: (() -> Void)?
        
    init(paywallInfo: HeliumPaywallInfo, trigger: String) {
        self.paywallInfo = paywallInfo
        self.trigger = trigger
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
        HeliumPaywallDelegateWrapper.shared.fireEvent(event)
    }
    
    public func getIsLoading() -> Bool {
        return isLoading;
    }
    
    func setDismissAction(_ action: @escaping () -> Void) {
        dismissAction = action
    }
    
    public func dismiss(dispatchEvent: Bool) {
        if (!isLoading) {
            if dispatchEvent {
                let event = PaywallDismissedEvent(
                    triggerName: trigger,
                    paywallName: paywallInfo.paywallTemplateName
                )
                HeliumPaywallDelegateWrapper.shared.fireEvent(event)
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
                HeliumPaywallDelegateWrapper.shared.fireEvent(event)
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
                    paywallName: "unknown",
                    error: "Second try - no paywall found for trigger.",
                    paywallUnavailableReason: .secondTryNoMatch
                )
                HeliumPaywallDelegateWrapper.shared.fireEvent(event)
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
            HeliumPaywallDelegateWrapper.shared.fireEvent(event)
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
        // Use new typed event
        let pressedEvent = PurchasePressedEvent(
            productId: selectedProductId,
            triggerName: trigger,
            paywallName: paywallInfo.paywallTemplateName
        )
        HeliumPaywallDelegateWrapper.shared.fireEvent(pressedEvent)
        
        isLoading = true
        let status = await HeliumPaywallDelegateWrapper.shared.handlePurchase(productKey: selectedProductId, triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName)
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
        isLoading = true;
        let status = await HeliumPaywallDelegateWrapper.shared.restorePurchases(
            triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName
        )
        defer { isLoading = false; }
        
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
            isFallback: isFallback
        )
        
        let event = PaywallOpenEvent(
            triggerName: trigger,
            paywallName: paywallInfo.paywallTemplateName,
            viewType: viewType,
            paywallUnavailableReason: fallbackReason
        )
        HeliumPaywallDelegateWrapper.shared.fireEvent(event)
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
        HeliumPaywallDelegateWrapper.shared.fireEvent(event)
    }
    
    public func onCustomAction(actionName: String, params: [String: Any]) {
        if (!isLoading) {
            let event = CustomPaywallActionEvent(
                actionName: actionName,
                params: params,
                triggerName: trigger,
                paywallName: paywallInfo.paywallTemplateName
            )
            HeliumPaywallDelegateWrapper.shared.fireEvent(event)
        }
    }
}


public class PrinterActionsDelegate: BaseActionsDelegate {
    
    public init () {}
    
    public func dismiss(dispatchEvent: Bool) {
        print("dismiss pressed");
    }
    
    public func dismissAll(dispatchEvent: Bool) {
        print("dismissAll pressed");
    }
    
    public func showSecondaryPaywall(uuid: String) {
        print("show secondary paywall");
    }
    
    public func onCTAPress(contentComponentName: String) {
        print("cta press \(contentComponentName)");
    }
    
    public func showScreen(screenId: String) {
        print("showing screen \(screenId)");
    }
    
    public func selectProduct(productId: String) {
        print("select product \(productId)");
    }
    
    public func makePurchase() async -> HeliumPaywallTransactionStatus {
        print("make purchase");
        return .purchased;
    }
    
    public func restorePurchases() async -> Bool {
        print("restore purchases")
        return false;
    }
    
    public func logRenderTime(timeTakenMS: UInt64, isFallback: Bool) {
        print("log render time");
    }
    
    public func logImpression(viewType: PaywallOpenViewType, fallbackReason: PaywallUnavailableReason?) {
        print("log impression")
    }
    
    public func logClosure() {
        print("log closure");
    }
    
    public func getIsLoading() -> Bool {
        return false;
    }
    
    public func onCustomAction(actionName: String, params: [String: Any]) {
        print("custom action: \(actionName) with params: \(params)");
    }
}
