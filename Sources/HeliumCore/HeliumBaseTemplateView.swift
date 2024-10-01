import Foundation
import SwiftUI
import SwiftyJSON


public protocol BaseTemplateView: View {
    init(paywallInfo: HeliumPaywallInfo, trigger: String)
}


public struct DynamicBaseTemplateView: BaseTemplateView {
    @Environment(\.dismiss) var dismiss
    @StateObject private var actionsDelegate: HeliumActionsDelegate
    @StateObject private var actionsDelegateWrapper: ActionsDelegateWrapper
    var templateValues: JSON
    
    public init(paywallInfo: HeliumPaywallInfo, trigger: String) {
        let delegate = HeliumActionsDelegate(paywallInfo: paywallInfo, trigger: trigger);
        _actionsDelegate = StateObject(wrappedValue: delegate)
        _actionsDelegateWrapper = StateObject(wrappedValue: ActionsDelegateWrapper(delegate: delegate));
        
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
