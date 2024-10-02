import Foundation
import SwiftUI
import HeliumCore

public class Helium {
    var controller: HeliumController?
    private var baseTemplateViewType: (any BaseTemplateView.Type)?
    private var fallbackPaywall: (any View)?
    
    public static let shared = Helium()
    
    public func presentUpsell(trigger: String, from viewController: UIViewController? = nil) {
        HeliumPaywallPresenter.shared.presentUpsell(trigger: trigger, from: viewController);
    }
    
    public func upsellViewForTrigger(trigger: String) -> AnyView {
        if case .downloadSuccess = self.downloadStatus() {
            let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger);
            
            guard let templatePaywallInfo = paywallInfo, let baseTemplateViewType = baseTemplateViewType else {
                return AnyView(self.fallbackPaywall!);
            }
            
            return AnyView(baseTemplateViewType.init(paywallInfo: templatePaywallInfo, trigger: trigger));
            
        } else if (self.fallbackPaywall != nil) {
            return AnyView(self.fallbackPaywall!);
        } else {
            return AnyView(EmptyView())
        }
    }
    
    public func previewPaywallTemplate(paywallTemplateName: String, from viewController: UIViewController? = nil) {
        HeliumPaywallPresenter.shared.presentUpsell(paywallTemplateName: paywallTemplateName, from: viewController);
    }
    
    public func getHeliumUserId() -> UUID? {
        if (self.controller == nil) {
            return nil;
        }
        return self.controller?.getUserId();
    }
    
    public func initializeAndFetchVariants(
        apiKey: String,
        heliumPaywallDelegate: HeliumPaywallDelegate,
        baseTemplateView: (any BaseTemplateView.Type)? = nil,
        fallbackPaywall: (any View)? = nil,
        useCache: Bool = false,
        triggers: [HeliumTrigger]? = nil
    ) async {
        self.controller = HeliumController(
            apiKey: apiKey,
            triggers: triggers
        )
        HeliumPaywallDelegateWrapper.shared.setDelegate(heliumPaywallDelegate);
        if (baseTemplateView == nil) {
            self.baseTemplateViewType = DynamicBaseTemplateView.self;
        } else {
            self.baseTemplateViewType = baseTemplateView;
        }
        
        if (fallbackPaywall != nil) {
            self.fallbackPaywall = fallbackPaywall;
            HeliumPaywallPresenter.shared.setFallback(fallbackPaywall: fallbackPaywall!);
        }
        
        await self.controller!.downloadConfig();
    }
    
    public func configure(
        apiKey: String,
        heliumPaywallDelegate: HeliumPaywallDelegate,
        fallbackPaywall: (any View)? = nil,
        baseTemplateView: (any BaseTemplateView.Type)? = nil
    ) {
        self.controller = HeliumController(
            apiKey: apiKey,
            triggers: []
        )

        HeliumPaywallDelegateWrapper.shared.setDelegate(heliumPaywallDelegate);
        if (baseTemplateView == nil) {
            self.baseTemplateViewType = DynamicBaseTemplateView.self;
        } else {
            self.baseTemplateViewType = baseTemplateView;
        }
        
        if (fallbackPaywall != nil) {
            HeliumPaywallPresenter.shared.setFallback(fallbackPaywall: fallbackPaywall!);
            self.fallbackPaywall = fallbackPaywall;
        }
    }
    
    public func downloadStatus() -> HeliumFetchedConfigStatus {
        return HeliumFetchedConfigManager.shared.downloadStatus;
    }
    
    public func getBaseTemplateView(paywallInfo: HeliumPaywallInfo?, trigger: String) -> AnyView {
        guard let viewType = baseTemplateViewType, let templatePaywallInfo = paywallInfo else {
            fatalError("Base template view not set up correctly. Please contact founders@tryhelium.com to get set up!")
        }
        return AnyView(viewType.init(paywallInfo: templatePaywallInfo, trigger: trigger))
    }
}

struct DynamicPaywallModifier: ViewModifier {
    @Binding var isPresented: Bool
    let trigger: String
    @StateObject private var configManager = HeliumFetchedConfigManager.shared
    
    @ViewBuilder
    func body(content: Content) -> some View {
        if case .downloadSuccess = configManager.downloadStatus,
           let paywallInfo = configManager.getPaywallInfoForTrigger(trigger),
           let clientName = configManager.getClientName() {
            content
                .fullScreenCover(isPresented: $isPresented) {
                    Helium.shared.getBaseTemplateView(paywallInfo: paywallInfo, trigger: trigger)
                }
        } else if case .notDownloadedYet = configManager.downloadStatus {
            content
        } else {
            content.fullScreenCover(isPresented: $isPresented) {
                Helium.shared.getBaseTemplateView(
                    paywallInfo: nil,
                    trigger: trigger
                )
            }
        }
    }
}

// Extension to make DynamicPaywallModifier easier to use
public extension View {
    func triggerUpsell(isPresented: Binding<Bool>, trigger: String) -> some View {
        self.modifier(DynamicPaywallModifier(isPresented: isPresented, trigger: trigger))
    }
}
