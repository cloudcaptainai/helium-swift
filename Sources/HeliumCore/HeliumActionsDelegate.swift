//
//  File.swift
//  
//
//  Created by Anish Doshi on 9/30/24.
//

import Foundation

public protocol BaseActionsDelegate {
    func dismiss();
    func onCTAPress(contentComponentName: String);
    func showScreen(screenId: String);
    func selectProduct(productId: String);
    func makePurchase() async -> Bool;
    func logImpression();
    func logDismissal();
}

public class ActionsDelegateWrapper: ObservableObject {
    private let delegate: BaseActionsDelegate
    
    public init(delegate: BaseActionsDelegate) {
        self.delegate = delegate
    }
    
    public func dismiss() {
        delegate.dismiss()
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
    
    @MainActor
    public func makePurchase() async -> Bool {
        await delegate.makePurchase()
    }
    
    public func logImpression() {
        delegate.logImpression()
    }
    
    public func logDismissal() {
        delegate.logDismissal()
    }
}

public class HeliumActionsDelegate: BaseActionsDelegate, ObservableObject {
    let paywallInfo: HeliumPaywallInfo
    let trigger: String
    @Published var selectedProductId: String
    @Published var isShowingModal: Bool = false
    @Published var showingModalScreen: String? = nil
    
    var dismissAction: (() -> Void)?
        
    init(paywallInfo: HeliumPaywallInfo, trigger: String) {
        self.paywallInfo = paywallInfo
        self.trigger = trigger
        self.selectedProductId = paywallInfo.productsOffered[0]
    }
    
    func setDismissAction(_ action: @escaping () -> Void) {
         self.dismissAction = action
     }
    
    public func dismiss() {
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(
            event: .paywallDismissed(triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName)
        )
        dismissAction?()
    }
    
    public func onCTAPress(contentComponentName: String) {
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(
            event: .ctaPressed(
                ctaName: contentComponentName,
                triggerName: trigger,
                paywallTemplateName: paywallInfo.paywallTemplateName
            )
        )
    }
    
    public func showScreen(screenId: String) {
        showingModalScreen = screenId
        isShowingModal = true
    }
    
    public func selectProduct(productId: String) {
        selectedProductId = productId
    }
    
    public func makePurchase() async -> Bool {
        print("Making purchase for product: \(selectedProductId)")
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event:
            .subscriptionPressed(productKey: selectedProductId, triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName))
        
        let status = await HeliumPaywallDelegateWrapper.shared.handlePurchase(productKey: selectedProductId, triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName)
        
        switch status {
        case .purchased, .restored:
            return true
        case .cancelled, .failed, .pending, .none:
            return false
        }
    }
    
    public func logImpression() {
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallOpen(triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName))
    }
    
    public func logDismissal() {
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallDismissed(triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName))
    }
}


public class PrinterActionsDelegate: BaseActionsDelegate {
    
    public init () {}
    
    public func dismiss() {
        print("dismiss pressed");
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
    
    public func makePurchase() async -> Bool {
        print("make purchase");
        return true;
    }
    
    public func logImpression() {
        print("log impression")
    }
    
    public func logDismissal() {
        print("log dismissal");
    }
}
