import Foundation
import SwiftUI
import SwiftyJSON


public protocol BaseTemplateView: View {
    init(paywallInfo: HeliumPaywallInfo, trigger: String)
}

public extension BaseTemplateView {
    init(paywallInfo: HeliumPaywallInfo, trigger: String, resolvedConfig: JSON?) {
        self.init(paywallInfo: paywallInfo, trigger: trigger)
    }
}


public struct DynamicBaseTemplateView: BaseTemplateView {
    
    @Environment(\.dismiss) var dismiss
    @Environment(\.paywallPresentationState) var presentationState: HeliumPaywallPresentationState
    @StateObject private var actionsDelegate: HeliumActionsDelegate
    @StateObject private var actionsDelegateWrapper: ActionsDelegateWrapper
    var templateValues: JSON
    var triggerName: String?
    
    public init(paywallInfo: HeliumPaywallInfo, trigger: String, resolvedConfig: JSON?) {
        let delegate = HeliumActionsDelegate(paywallInfo: paywallInfo, trigger: trigger);
        _actionsDelegate = StateObject(wrappedValue: delegate)
        _actionsDelegateWrapper = StateObject(wrappedValue: ActionsDelegateWrapper(delegate: delegate));
        
        self.templateValues = resolvedConfig ?? JSON([:]);
        self.triggerName = trigger;
    }
    
    public init(paywallInfo: HeliumPaywallInfo, trigger: String) {
        let delegate = HeliumActionsDelegate(paywallInfo: paywallInfo, trigger: trigger);
        _actionsDelegate = StateObject(wrappedValue: delegate)
        _actionsDelegateWrapper = StateObject(wrappedValue: ActionsDelegateWrapper(delegate: delegate));
        
        let encoder = JSONEncoder()
        let jsonData = try! encoder.encode(paywallInfo.resolvedConfig)
        self.templateValues = try! JSON(data: jsonData);
        self.triggerName = trigger;
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.all)
        .environmentObject(actionsDelegateWrapper)
        .onAppear {
            if !presentationState.firstOnAppearHandled {
                presentationState.handleOnAppear()
            }
        }
        .onDisappear {
            presentationState.handleOnDisappear()
        }
        .onReceive(presentationState.$isOpen) { newIsOpen in
            if newIsOpen {
                actionsDelegateWrapper.logImpression()
            } else {
                actionsDelegateWrapper.logClosure()
            }
        }
    }
}

extension EnvironmentValues {
    
    @MainActor var dismiss: () -> Void {
        {
            presentationMode.wrappedValue.dismiss()
        }
    }
}
