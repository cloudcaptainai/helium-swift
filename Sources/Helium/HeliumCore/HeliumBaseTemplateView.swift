import Foundation
import SwiftUI

protocol BaseTemplateView: View {
    init(paywallInfo: HeliumPaywallInfo, trigger: String, resolvedConfig: JSON?)
}

public struct DynamicBaseTemplateView: BaseTemplateView {
    
    @Environment(\.dismiss) var dismiss
    @Environment(\.paywallPresentationState) var presentationState: HeliumPaywallPresentationState
    @StateObject private var actionsDelegate: HeliumActionsDelegate
    @StateObject private var actionsDelegateWrapper: ActionsDelegateWrapper
    var templateValues: JSON
    var triggerName: String?
    
    init(paywallInfo: HeliumPaywallInfo, trigger: String, resolvedConfig: JSON?) {
        let delegate = HeliumActionsDelegate(paywallInfo: paywallInfo, trigger: trigger);
        _actionsDelegate = StateObject(wrappedValue: delegate)
        _actionsDelegateWrapper = StateObject(wrappedValue: ActionsDelegateWrapper(delegate: delegate));
        
        self.templateValues = resolvedConfig ?? JSON([:]);
        self.triggerName = trigger;
    }
    
    public var body: some View {
        // Directly use DynamicWebView
        DynamicWebView(
            json: templateValues,
            actionsDelegate: actionsDelegateWrapper,
            triggerName: triggerName
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.all)
        .onAppear {
            actionsDelegate.setDismissAction {
                dismiss()
            }
            if !presentationState.firstOnAppearHandled {
                presentationState.handleOnAppear()
            }
        }
        .onDisappear {
            presentationState.handleOnDisappear()
        }
        .onReceive(presentationState.$isOpen) { newIsOpen in
            if presentationState.viewType == .presented {
                return
            }
            if newIsOpen {
                actionsDelegateWrapper.logImpression(viewType: presentationState.viewType)
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