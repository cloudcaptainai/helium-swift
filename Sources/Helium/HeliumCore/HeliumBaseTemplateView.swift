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
        DynamicWebView(
            json: templateValues["baseStack"]["componentProps"],
            actionsDelegate: actionsDelegateWrapper,
            triggerName: triggerName
        )
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
