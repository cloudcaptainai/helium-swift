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
    func logImpression(viewType: PaywallOpenViewType);
    func logClosure();
    func getIsLoading() -> Bool;
    func logRenderTime(timeTakenMS: UInt64);
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
    
    public func logRenderTime(timeTakenMS: UInt64) {
        delegate.logRenderTime(timeTakenMS: timeTakenMS);
    }
    
    @MainActor
    public func makePurchase() async -> HeliumPaywallTransactionStatus {
        await delegate.makePurchase();
    }
    
    @MainActor
    public func restorePurchases() async -> Bool {
        await delegate.restorePurchases();
    }
    
    public func logImpression(viewType: PaywallOpenViewType) {
        delegate.logImpression(viewType: viewType)
    }
    
    public func logClosure() {
        delegate.logClosure()
    }
    
    public func getIsLoading() -> Bool{
        return delegate.getIsLoading();
    }
}

public class HeliumActionsDelegate: BaseActionsDelegate, ObservableObject {
    let paywallInfo: HeliumPaywallInfo
    let trigger: String
    @Published var selectedProductId: String
    @Published var isShowingModal: Bool = false
    @Published var showingModalScreen: String? = nil
    private var isLoading: Bool = false
    
    var dismissAction: (() -> Void)?
        
    init(paywallInfo: HeliumPaywallInfo, trigger: String) {
        self.paywallInfo = paywallInfo
        self.trigger = trigger
        self.selectedProductId = "";
        if (!paywallInfo.productsOffered.isEmpty) {
            self.selectedProductId = paywallInfo.productsOffered[0] ?? "";
        }
    }
    
    public func logRenderTime(timeTakenMS: UInt64) {
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallWebViewRendered(triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName, webviewRenderTimeTakenMS: timeTakenMS))
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
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(
                    event: .paywallDismissed(triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName)
                )
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
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(
                    event: .paywallDismissed(triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName, dismissAll: true)
                )
            }
            HeliumPaywallPresenter.shared.hideAllUpsells(onComplete: { [weak self] in
                self?.dismissAction?()
            })
        }
    }
    
    public func showSecondaryPaywall(uuid: String) {
        if (!isLoading) {
            if let trigger = HeliumFetchedConfigManager.shared.getTriggerFromPaywallUuid(uuid) {
                HeliumPaywallPresenter.shared.presentUpsell(trigger: trigger)
            } else {
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(
                    event: .paywallOpenFailed(triggerName: "\(trigger)_secondTry", paywallTemplateName: "unknown")
                )
            }
        }
    }
    
    public func onCTAPress(contentComponentName: String) {
        if (!isLoading) {
            HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(
                event: .ctaPressed(
                    ctaName: contentComponentName,
                    triggerName: trigger,
                    paywallTemplateName: paywallInfo.paywallTemplateName
                )
            )
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
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event:
            .subscriptionPressed(productKey: selectedProductId, triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName))
        
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
    
    public func logImpression(viewType: PaywallOpenViewType) {
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallOpen(triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName, viewType: viewType.rawValue))
    }
    
    public func logClosure() {
        let closeEvent: HeliumPaywallEvent = .paywallClose(triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName)
        DispatchQueue.main.async {
            HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: closeEvent)
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
    
    public func logRenderTime(timeTakenMS: UInt64) {
        print("log render time");
    }
    
    public func logImpression(viewType: PaywallOpenViewType) {
        print("log impression")
    }
    
    public func logClosure() {
        print("log closure");
    }
    
    public func getIsLoading() -> Bool {
        return false;
    }
}
