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
    func makePurchase() async -> HeliumPaywallTransactionStatus;
    func restorePurchases() async -> Bool;
    func logImpression();
    func logClosure();
    func getIsLoading() -> Bool;
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
    public func makePurchase() async -> HeliumPaywallTransactionStatus {
        await delegate.makePurchase();
    }
    
    @MainActor
    public func restorePurchases() async -> Bool {
        await delegate.restorePurchases();
    }
    
    public func logImpression() {
        delegate.logImpression()
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
    @Published var isLoading: Bool = false
    
    var dismissAction: (() -> Void)?
        
    init(paywallInfo: HeliumPaywallInfo, trigger: String) {
        self.paywallInfo = paywallInfo
        self.trigger = trigger
        self.selectedProductId = "";
        if (!paywallInfo.productsOffered.isEmpty) {
            self.selectedProductId = paywallInfo.productsOffered[0] ?? "";
        }
    }
    
    func setDismissAction(_ action: @escaping () -> Void) {
         self.dismissAction = action
    }
    
    public func getIsLoading() -> Bool {
        return isLoading;
    }
    
    public func dismiss() {
        if (!isLoading) {
            HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(
                event: .paywallDismissed(triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName)
            )
            dismissAction?()
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
        
        isLoading = true;
        let status = await HeliumPaywallDelegateWrapper.shared.handlePurchase(productKey: selectedProductId, triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName)
        defer { isLoading = false; }
        
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
    
    public func logImpression() {
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallOpen(triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName))
    }
    
    public func logClosure() {
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallClose(triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName))
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
    
    public func makePurchase() async -> HeliumPaywallTransactionStatus {
        print("make purchase");
        return .purchased;
    }
    
    public func restorePurchases() async -> Bool {
        print("restore purchases")
        return false;
    }
    
    public func logImpression() {
        print("log impression")
    }
    
    public func logClosure() {
        print("log closure");
    }
    
    public func getIsLoading() -> Bool {
        return false;
    }
}
