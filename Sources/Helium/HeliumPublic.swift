import Foundation
import SwiftUI
import HeliumCore

public class Helium {
    var controller: HeliumController?
    private var baseTemplateViewType: (any BaseTemplateView.Type)?
    private var fallbackPaywall: (any View)?
    private var initialized: Bool = false;
    
    public static let shared = Helium()
    
    public func presentUpsell(trigger: String, from viewController: UIViewController? = nil) {
        HeliumPaywallPresenter.shared.presentUpsell(trigger: trigger, from: viewController);
    }
    
    
    public func hideUpsell() -> Bool {
        return HeliumPaywallPresenter.shared.hideUpsell();
    }
    
    public func upsellViewForTrigger(trigger: String) -> AnyView {
        if (!initialized) {
            fatalError("Helium.initialize() needs to be called before presenting a paywall. Please contact founders@tryhelium.com to get set up!");
        }

        if self.paywallsLoaded() {
            let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger);
            
            guard let templatePaywallInfo = paywallInfo, let baseTemplateViewType = baseTemplateViewType else {
                let fallbackView = AnyView(fallbackPaywall!)
                return AnyView(HeliumFallbackViewWrapper(trigger: trigger) {
                    fallbackView
                })
            }
            
            do {
                return AnyView(baseTemplateViewType.init(paywallInfo: templatePaywallInfo, trigger: trigger));
            } catch {
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallOpenFailed(
                    triggerName: trigger,
                    paywallTemplateName: templatePaywallInfo.paywallTemplateName
                ));
                let fallbackView = AnyView(fallbackPaywall!)
                return AnyView(HeliumFallbackViewWrapper(trigger: trigger) {
                    fallbackView
                })
            };
            
        } else {
            let fallbackView = AnyView(fallbackPaywall!)
            return AnyView(HeliumFallbackViewWrapper(trigger: trigger) {
                fallbackView
            })
        }
    }
    
    public func getHeliumUserId() -> String? {
        if (self.controller == nil) {
            return nil;
        }
        return HeliumIdentityManager.shared.getUserId();
    }
    
    public func initialize(
        apiKey: String,
        heliumPaywallDelegate: HeliumPaywallDelegate,
        fallbackPaywall: (any View),
        baseTemplateView: (any BaseTemplateView.Type)? = nil,
        triggers: [HeliumTrigger]? = nil,
        customUserId: String? = nil
    ) {
        if (customUserId != nil) {
            self.overrideUserId(newUserId: customUserId!);
        }
        self.initialized = true;
        self.fallbackPaywall = fallbackPaywall;
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
        
        self.controller!.downloadConfig();
    }
    
    public func paywallsLoaded() -> Bool {
        if case .downloadSuccess = HeliumFetchedConfigManager.shared.downloadStatus,
           HeliumAssetManager.shared.imageStatus.downloadStatus == .downloaded {
            return true;
        }
        return false;
    }
    
    public func overrideUserId(newUserId: String) {
        HeliumIdentityManager.shared.setCustomUserId(newUserId);
        // Make sure to re-identify the user if we've already set analytics.
        self.controller?.identifyUser(userId: newUserId);
    }
}
