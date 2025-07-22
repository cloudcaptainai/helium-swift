import Foundation
import SwiftUI
import StoreKit

public class Helium {
    var controller: HeliumController?
    private var baseTemplateViewType: (any BaseTemplateView.Type)?
    private var initialized: Bool = false;
    
    public static let shared = Helium()
    
    public func presentUpsell(trigger: String, from viewController: UIViewController? = nil) {
        if !checkShouldShowBeforePresenting(trigger: trigger) {
            return
        }
        
        HeliumPaywallPresenter.shared.presentUpsell(trigger: trigger, from: viewController)
    }
    func checkShouldShowBeforePresenting(trigger: String) -> Bool {
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        if paywallInfo?.shouldShow == false {
            HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(
                event: .paywallSkipped(triggerName: trigger)
            )
            return false
        }
        return true
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
    
    fileprivate func getHeliumUserIdAsAppAccountToken() -> UUID? {
        guard let heliumUserId = getHeliumUserId() else { return nil }
        return UUID(uuidString: heliumUserId)
    }
    
    public func getPaywallInfo(trigger: String) -> PaywallInfo? {
        guard let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger) else {
            return nil
        }
        return PaywallInfo(paywallTemplateName: paywallInfo.paywallTemplateName, shouldShow: paywallInfo.shouldShow)
    }
    
    /// Returns true if Helium is initialized, this trigger is configured, and associated paywall is ready to be presented.
    public func triggerAvailable(trigger: String) -> Bool {
        return getPaywallInfo(trigger: trigger) != nil
    }
    
    
    /// Initializes the Helium paywall system with configuration options.
    ///
    /// @param apiKey Helium API key
    /// @param heliumPaywallDelegate Delegate to handle paywall events and callbacks
    /// @param fallbackPaywall  Default view to display when paywall fails to load
    /// @param baseTemplateView  Optional custom base template view type (defaults to DynamicBaseTemplateView)
    /// @param triggers  Optional array of trigger identifiers to configure
    /// @param customUserId  Optional custom user ID to override default user identification
    /// @param customAPIEndpoint  Optional custom API endpoint URL
    /// @param customUserTraits  Optional custom user traits for targeting
    /// @param onAppEventConfigs  Optional configurations for predefined triggers such as "on\_app\_open"
    /// @param revenueCatAppUserId  Optional RevenueCat user ID for integration. Important if you are using RevenueCat to handle purchases!
    /// @param fallbackPaywallPerTrigger  Optional trigger-specific fallback views
    ///
    public func initialize(
        apiKey: String,
        heliumPaywallDelegate: HeliumPaywallDelegate,
        fallbackPaywall: (any View),
        baseTemplateView: (any BaseTemplateView.Type)? = nil,
        triggers: [String]? = nil,
        customUserId: String? = nil,
        customAPIEndpoint: String? = nil,
        customUserTraits: HeliumUserTraits? = nil,
        onAppEventConfigs: [HeliumOnAppEventConfig]? = [HeliumOnAppEventConfig(appTrigger: .defaultForAppEvents)],
        revenueCatAppUserId: String? = nil,
        fallbackPaywallPerTrigger: [String: any View]? = nil
    ) {
        if initialized {
            return
        }
        let isFreshInstall = !HeliumIdentityManager.shared.hasIdentity()
        if (customUserId != nil) {
            self.overrideUserId(newUserId: customUserId!);
        }
        if (customUserTraits != nil) {
            HeliumIdentityManager.shared.setCustomUserTraits(traits: customUserTraits!);
        }
        
        HeliumIdentityManager.shared.revenueCatAppUserId = revenueCatAppUserId
        
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
        
        if let onAppEventConfigs {
            HeliumOnAppEventConfigManager.shared.configs = onAppEventConfigs
            HeliumOnAppEventConfigManager.shared.startTiming(
                appTrigger: isFreshInstall ? .onAppInstallTrigger : .onAppLaunchTrigger
            )
        }
        
        // Ensure this doesn't fire upon app install/launch. Both to avoid conflicts with those
        // triggers and for consistency.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }
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
    
    @objc
    private func appDidBecomeActive() {
        HeliumOnAppEventConfigManager.shared.startTiming(
            appTrigger: .onAppOpenTrigger
        )
    }
}

@available(iOS 15.0, *)
extension Product {
    /// Initiates a product purchase with specific configuration to support Helium analytics.
    /// This method provides a wrapper around the standard purchase flow
    ///
    /// - Parameter options: A set of options to configure the purchase.
    /// - Returns: The result of the purchase.
    /// - Throws: A `PurchaseError` or `StoreKitError` or `HeliumPurchaseError` if an issue with appAccountToken.
    @MainActor public func heliumPurchase(
        options: Set<Product.PurchaseOption> = []
    ) async throws -> Product.PurchaseResult {
        var newOptions: Set<Product.PurchaseOption> = options
        
        let hasExistingAppAccountToken = newOptions.contains { option in
            return String(describing: option).contains("appAccountToken")
        }
        if hasExistingAppAccountToken {
            throw HeliumPurchaseError.appAccountTokenAlreadyExists
        }
        
        guard let appAccountToken = UUID(uuidString: HeliumIdentityManager.shared.getHeliumPersistentId()) else {
            throw HeliumPurchaseError.invalidPersistentId
        }
        newOptions.insert(.appAccountToken(appAccountToken))
        
        return try await purchase(options: newOptions)
    }
}

public enum HeliumPurchaseError: Error {
    case appAccountTokenAlreadyExists
    case invalidPersistentId
    
    public var errorDescription: String? {
        switch self {
        case .appAccountTokenAlreadyExists:
            return "Options already contain an appAccountToken. Remove it or use the customAppAccountToken parameter instead."
        case .invalidPersistentId:
            return "Helium persistent ID is not a UUID! 😅"
        }
    }
}
