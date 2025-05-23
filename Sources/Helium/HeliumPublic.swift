import Foundation
import SwiftUI

public class Helium {
    var controller: HeliumController?
    private var baseTemplateViewType: (any BaseTemplateView.Type)?
    private var initialized: Bool = false;
    
    public static let shared = Helium()
    
    public func presentUpsell(trigger: String, from viewController: UIViewController? = nil) {
        HeliumPaywallPresenter.shared.presentUpsell(trigger: trigger, from: viewController);
    }
    
    public func getDownloadStatus() -> HeliumFetchedConfigStatus {
        return HeliumFetchedConfigManager.shared.downloadStatus;
    }
    
    public func hideUpsell() -> Bool {
        return HeliumPaywallPresenter.shared.hideUpsell();
    }
    
    public func hideAllUpsells() {
        return HeliumPaywallPresenter.shared.hideAllUpsells()
    }
    
    public func upsellViewForTrigger(trigger: String) -> AnyView {
        if (!initialized) {
            fatalError("Helium.shared.initialize() needs to be called before presenting a paywall. Please visit docs.tryhelium.com or message founders@tryhelium.com to get set up!");
        }
        
        if self.paywallsLoaded() {
            let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger);
            
            guard let templatePaywallInfo = paywallInfo, let baseTemplateViewType = baseTemplateViewType else {
                let fallbackView = HeliumFallbackViewManager.shared.getFallbackForTrigger(trigger: trigger)
                return AnyView(HeliumFallbackViewWrapper(trigger: trigger) {
                    fallbackView
                })
            }
            
            do {
                if (paywallInfo?.forceShowFallback != nil && (paywallInfo?.forceShowFallback)!) {
                    let fallbackView = HeliumFallbackViewManager.shared.getFallbackForTrigger(trigger: trigger)
                    return AnyView(HeliumFallbackViewWrapper(trigger: trigger) {
                        fallbackView
                    })
                }
                return AnyView(baseTemplateViewType.init(
                    paywallInfo: templatePaywallInfo,
                    trigger: trigger,
                    resolvedConfig: HeliumFetchedConfigManager.shared.getResolvedConfigJSONForTrigger(trigger)
                ));
            } catch {
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallOpenFailed(
                    triggerName: trigger,
                    paywallTemplateName: templatePaywallInfo.paywallTemplateName
                ));
                let fallbackView = HeliumFallbackViewManager.shared.getFallbackForTrigger(trigger: trigger)
                return AnyView(HeliumFallbackViewWrapper(trigger: trigger) {
                    fallbackView
                })
            };
            
        } else {
            let fallbackView = HeliumFallbackViewManager.shared.getFallbackForTrigger(trigger: trigger)
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
        triggers: [String]? = nil,
        customUserId: String? = nil,
        customAPIEndpoint: String? = nil,
        customUserTraits: HeliumUserTraits? = nil,
        fallbackPaywallPerTrigger: [String: any View]? = nil
    ) {
        if (customUserId != nil) {
            self.overrideUserId(newUserId: customUserId!);
        }
        if (customUserTraits != nil) {
            HeliumIdentityManager.shared.setCustomUserTraits(traits: customUserTraits!);
        }
        
        self.initialized = true;
        HeliumFallbackViewManager.shared.setDefaultFallback(fallbackView: AnyView(fallbackPaywall));
        
        // Set up trigger-specific fallback views if provided
        if let triggerFallbacks = fallbackPaywallPerTrigger {
            var triggerToViewMap: [String: AnyView] = [:]
            for (trigger, view) in triggerFallbacks {
                triggerToViewMap[trigger] = AnyView(view)
            }
            HeliumFallbackViewManager.shared.setTriggerToFallback(toSet: triggerToViewMap)
        }
        
        self.controller = HeliumController(
            apiKey: apiKey
        )
        self.controller?.logInitializeEvent();
        
        HeliumPaywallDelegateWrapper.shared.setDelegate(heliumPaywallDelegate);
        if (baseTemplateView == nil) {
            self.baseTemplateViewType = DynamicBaseTemplateView.self;
        } else {
            self.baseTemplateViewType = baseTemplateView;
        }
        if (customAPIEndpoint != nil) {
            self.controller!.setCustomAPIEndpoint(endpoint: customAPIEndpoint!);
        } else {
            self.controller!.clearCustomAPIEndpoint()
        }
        self.controller!.downloadConfig();
        
        WebViewManager.shared.preCreateFirstWebView()
    }
    
    public func paywallsLoaded() -> Bool {
        if case .downloadSuccess = HeliumFetchedConfigManager.shared.downloadStatus {
            return true;
        }
        return false;
    }
    
    public func overrideUserId(newUserId: String, traits: HeliumUserTraits? = nil) {
        HeliumIdentityManager.shared.setCustomUserId(newUserId);
        // Make sure to re-identify the user if we've already set analytics.
        self.controller?.identifyUser(userId: newUserId, traits: traits);
    }
}
