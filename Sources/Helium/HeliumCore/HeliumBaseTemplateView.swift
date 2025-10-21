import Foundation
import SwiftUI

enum TemplateError: Error {
    case missingRequiredFields(String)
}

protocol BaseTemplateView: View {
    init(paywallInfo: HeliumPaywallInfo, trigger: String, fallbackReason: PaywallUnavailableReason?, resolvedConfig: JSON?, backupResolvedConfig: JSON?) throws
}

public struct DynamicBaseTemplateView: BaseTemplateView {
    
    @Environment(\.dismiss) var dismiss
    @Environment(\.paywallPresentationState) var presentationState: HeliumPaywallPresentationState
    @StateObject private var actionsDelegate: HeliumActionsDelegate
    @StateObject private var actionsDelegateWrapper: ActionsDelegateWrapper
    var componentPropsJSON: JSON
    var backupComponentPropsJSON: JSON?
    var triggerName: String?
    let fallbackReason: PaywallUnavailableReason?
    
    init(paywallInfo: HeliumPaywallInfo, trigger: String, fallbackReason: PaywallUnavailableReason?, resolvedConfig: JSON?, backupResolvedConfig: JSON? = nil) throws {
        let delegate = HeliumActionsDelegate(paywallInfo: paywallInfo, trigger: trigger);
        _actionsDelegate = StateObject(wrappedValue: delegate)
        _actionsDelegateWrapper = StateObject(wrappedValue: ActionsDelegateWrapper(delegate: delegate));
        
        let templateValues = resolvedConfig ?? JSON([:])
        
        // Validate required fields exist
        guard templateValues["baseStack"].exists(),
              templateValues["baseStack"]["componentProps"].exists() else {
            throw TemplateError.missingRequiredFields("Missing baseStack or componentProps in template configuration")
        }
        
        self.componentPropsJSON = templateValues["baseStack"]["componentProps"]
        self.triggerName = trigger;
        self.fallbackReason = fallbackReason
        if let backupResolvedConfig {
            if backupResolvedConfig["baseStack"].exists(),
               backupResolvedConfig["baseStack"]["componentProps"].exists() {
                backupComponentPropsJSON = backupResolvedConfig["baseStack"]["componentProps"]
            }
        }
    }
    
    public var body: some View {
        // Use validated componentProps
        DynamicWebView(
            json: componentPropsJSON,
            backupJson: backupComponentPropsJSON,
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
                actionsDelegateWrapper.logImpression(viewType: presentationState.viewType, fallbackReason: fallbackReason)
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
