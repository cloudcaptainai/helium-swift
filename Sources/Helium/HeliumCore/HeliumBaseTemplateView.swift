import Foundation
import SwiftUI

enum TemplateError: Error {
    case missingRequiredFields(String)
}

protocol BaseTemplateView: View {
    init(paywallInfo: HeliumPaywallInfo, trigger: String, fallbackReason: PaywallUnavailableReason?, filePath: String, backupFilePath: String?, resolvedConfig: JSON?) throws
}

public struct DynamicBaseTemplateView: BaseTemplateView {
    
    @Environment(\.dismiss) var dismiss
    @Environment(\.paywallPresentationState) var presentationState: HeliumPaywallPresentationState
    @StateObject private var actionsDelegate: HeliumActionsDelegate
    @StateObject private var actionsDelegateWrapper: ActionsDelegateWrapper
    let filePath: String
    let backupFilePath: String?
    var componentPropsJSON: JSON
    var triggerName: String?
    let fallbackReason: PaywallUnavailableReason?
    
    init(paywallInfo: HeliumPaywallInfo, trigger: String, fallbackReason: PaywallUnavailableReason?, filePath: String, backupFilePath: String?, resolvedConfig: JSON?) throws {
        let delegate = HeliumActionsDelegate(paywallInfo: paywallInfo, trigger: trigger);
        _actionsDelegate = StateObject(wrappedValue: delegate)
        _actionsDelegateWrapper = StateObject(wrappedValue: ActionsDelegateWrapper(delegate: delegate));
        
        self.filePath = filePath
        self.backupFilePath = backupFilePath
        
        let templateValues = resolvedConfig ?? JSON([:])
        
        // Validate required fields exist
        guard templateValues["baseStack"].exists(),
              templateValues["baseStack"]["componentProps"].exists() else {
            throw TemplateError.missingRequiredFields("Missing baseStack or componentProps in template configuration")
        }
        
        self.componentPropsJSON = templateValues["baseStack"]["componentProps"]
        self.triggerName = trigger;
        self.fallbackReason = fallbackReason
    }
    
    public var body: some View {
        // Use validated componentProps
        DynamicWebView(
            filePath: filePath,
            backupFilePath: backupFilePath,
            json: componentPropsJSON,
            actionsDelegate: actionsDelegateWrapper,
            triggerName: triggerName
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.all)
        .onAppear {
            actionsDelegate.setDismissAction {
                dismiss()
            }
            if presentationState.viewType != .presented {
                if !presentationState.isOpen {
                    presentationState.isOpen = true
                    actionsDelegateWrapper.logImpression(viewType: presentationState.viewType, fallbackReason: fallbackReason)
                }
            }
        }
        .onDisappear {
            if presentationState.viewType != .presented {
                if presentationState.isOpen {
                    presentationState.isOpen = false
                    actionsDelegateWrapper.logClosure()
                }
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
