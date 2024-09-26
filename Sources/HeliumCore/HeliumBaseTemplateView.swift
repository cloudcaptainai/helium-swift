import Foundation
import SwiftUI
import SwiftyJSON


public protocol BaseTemplateView: View {
    init(paywallInfo: HeliumPaywallInfo, trigger: String)
}

class ActionsDelegate: ObservableObject {
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
    
    func dismiss() {
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(
            event: .paywallDismissed(triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName)
        )
        dismissAction?()
    }
    
    func onCTAPress(contentComponentName: String) {
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(
            event: .ctaPressed(
                ctaName: contentComponentName,
                triggerName: trigger,
                paywallTemplateName: paywallInfo.paywallTemplateName
            )
        )
    }
    
    func showScreen(screenId: String) {
        showingModalScreen = screenId
        isShowingModal = true
    }
    
    func selectProduct(productId: String) {
        selectedProductId = productId
    }
    
    func makePurchase() async throws -> Bool {
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
    
    func logImpression() {
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallOpen(triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName))
    }
    
    func logDismissal() {
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallDismissed(triggerName: trigger, paywallTemplateName: paywallInfo.paywallTemplateName))
    }
}

public struct DynamicBaseTemplateView: BaseTemplateView {
    @Environment(\.dismiss) var dismiss
    @StateObject private var actionsDelegate: ActionsDelegate
    var templateValues: JSON
    
    public init(paywallInfo: HeliumPaywallInfo, trigger: String) {
        _actionsDelegate = StateObject(wrappedValue: ActionsDelegate(paywallInfo: paywallInfo, trigger: trigger))
        
        let encoder = JSONEncoder()
        let jsonData = try! encoder.encode(paywallInfo.resolvedConfig)
        self.templateValues = try! JSON(data: jsonData)
    }
    
    public var body: some View {
        GeometryReader { reader in
            if templateValues["baseStack"].exists() {
                DynamicPositionedComponent(
                    json: templateValues["baseStack"],
                    geometryProxy: reader
                )
                .adaptiveSheet(isPresented: $actionsDelegate.isShowingModal, heightFraction: 0.45) {
                    if let modalScreenToShow = actionsDelegate.showingModalScreen,
                       templateValues[modalScreenToShow].exists() {
                        DynamicPositionedComponent(
                            json: templateValues[modalScreenToShow],
                            geometryProxy: reader
                        )
                    }
                }
            }
        }
        .onAppear {
            actionsDelegate.setDismissAction {
                dismiss()
            }
            actionsDelegate.logImpression()
        }
        .onDisappear {
            actionsDelegate.logDismissal()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.all)
        .environmentObject(actionsDelegate)
    }
}

extension EnvironmentValues {
    
    @MainActor var dismiss: () -> Void {
        {
            presentationMode.wrappedValue.dismiss()
        }
    }
}
