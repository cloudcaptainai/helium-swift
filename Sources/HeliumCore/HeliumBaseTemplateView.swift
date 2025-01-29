import Foundation
import SwiftUI
import SwiftyJSON


public protocol BaseTemplateView: View {
    init(paywallInfo: HeliumPaywallInfo, trigger: String, resolvedConfig: JSON?)
}


public struct DynamicBaseTemplateView: BaseTemplateView {
    @Environment(\.dismiss) var dismiss
    @StateObject private var actionsDelegate: HeliumActionsDelegate
    @StateObject private var actionsDelegateWrapper: ActionsDelegateWrapper
    var templateValues: JSON
    var triggerName: String?
    
    public init(paywallInfo: HeliumPaywallInfo, trigger: String, resolvedConfig: JSON?) {
        let delegate = HeliumActionsDelegate(paywallInfo: paywallInfo, trigger: trigger);
        _actionsDelegate = StateObject(wrappedValue: delegate)
        _actionsDelegateWrapper = StateObject(wrappedValue: ActionsDelegateWrapper(delegate: delegate));
        
        let startTime = Date()
        self.templateValues = resolvedConfig ?? JSON([:]);
        self.triggerName = trigger;
        let endTime = Date()
        let timeElapsed = endTime.timeIntervalSince(startTime)
        print("JSON encoding and parsing took \(timeElapsed) seconds")
        
    }
    
    public var body: some View {
        GeometryReader { reader in
            DynamicPositionedComponent(
                json: templateValues["baseStack"],
                geometryProxy: reader,
                triggerName: triggerName
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
        .onAppear {
            actionsDelegate.setDismissAction {
                dismiss()
            }
            actionsDelegateWrapper.logImpression()
        }
        .onDisappear {
            actionsDelegateWrapper.logClosure()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.all)
        .environmentObject(actionsDelegateWrapper)
    }
}

extension EnvironmentValues {
    
    @MainActor var dismiss: () -> Void {
        {
            presentationMode.wrappedValue.dismiss()
        }
    }
}
