import Foundation
import SwiftUI
import StoreKit

struct UpsellViewResult {
    let view: AnyView
    let isFallback: Bool
}

public class Helium {
    var controller: HeliumController?
    private var baseTemplateViewType: (any BaseTemplateView.Type)?
    private var initialized: Bool = false;
    
    public static let shared = Helium()
    
    public func presentUpsell(trigger: String, from viewController: UIViewController? = nil) {
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        if paywallInfo?.shouldShow == false {
            HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(
                event: .paywallSkipped(triggerName: trigger)
            )
            return
        }
        
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
        return upsellViewResultFor(trigger: trigger).view
    }
    
    func upsellViewResultFor(trigger: String) -> UpsellViewResult {
        if (!initialized) {
            fatalError("Helium.shared.initialize() needs to be called before presenting a paywall. Please visit docs.tryhelium.com or message founders@tryhelium.com to get set up!");
        }
        
        
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        if paywallsLoaded() && HeliumFetchedConfigManager.shared.hasBundles() {
            
            guard let templatePaywallInfo = paywallInfo else {
                return fallbackViewFor(trigger: trigger, templateName: nil)
            }
            if templatePaywallInfo.forceShowFallback == true {
                return fallbackViewFor(trigger: trigger, templateName: templatePaywallInfo.paywallTemplateName)
            }
            
            do {
                let paywallView = AnyView(DynamicBaseTemplateView(
                    paywallInfo: templatePaywallInfo,
                    trigger: trigger,
                    resolvedConfig: HeliumFetchedConfigManager.shared.getResolvedConfigJSONForTrigger(trigger)
                ))
                return UpsellViewResult(view: paywallView, isFallback: false)
            } catch {
                return fallbackViewFor(trigger: trigger, templateName: templatePaywallInfo.paywallTemplateName)
            };
            
        } else {
            return fallbackViewFor(trigger: trigger, templateName: paywallInfo?.paywallTemplateName)
        }
    }
    
    private func fallbackViewFor(trigger: String, templateName: String?) -> UpsellViewResult {
        var result: AnyView
        if let fallbackPaywallInfo = HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger) {
            result = AnyView(
                DynamicBaseTemplateView(
                    paywallInfo: fallbackPaywallInfo,
                    trigger: trigger,
                    resolvedConfig: HeliumFallbackViewManager.shared.getResolvedConfigJSONForTrigger(trigger)
                )
            )
        } else {
            let fallbackView = HeliumFallbackViewManager.shared.getFallbackForTrigger(trigger: trigger)
            result = AnyView(HeliumFallbackViewWrapper(trigger: trigger) {
                fallbackView
            })
        }
        return UpsellViewResult(view: result, isFallback: true)
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
        return PaywallInfo(paywallTemplateName: paywallInfo.paywallTemplateName, shouldShow: paywallInfo.shouldShow ?? true)
    }
    
    /// Initializes the Helium paywall system with configuration options.
    ///
    /// @param apiKey Helium API key
    /// @param heliumPaywallDelegate Delegate to handle paywall events and callbacks
    /// @param fallbackPaywall  Default view to display when paywall fails to load. fallbackAssetsConfig and fallbackPaywallPerTrigger will take precedence over this.
    /// @param baseTemplateView  Optional custom base template view type (defaults to DynamicBaseTemplateView)
    /// @param triggers  Optional array of trigger identifiers to configure
    /// @param customUserId  Optional custom user ID to override default user identification
    /// @param customAPIEndpoint  Optional custom API endpoint URL
    /// @param customUserTraits  Optional custom user traits for targeting
    /// @param appAttributionToken - Optional Set this if you use a custom appAccountToken with your StoreKit purchases.
    /// @param revenueCatAppUserId  Optional RevenueCat user ID for integration. Important if you are using RevenueCat to handle purchases!
    /// @param fallbackBundleURL (Optional) The URL to a fallback bundle downloaded from the dashboard..
    /// @param fallbackPaywallPerTrigger  Optional trigger-specific fallback views
    ///
    public func initialize(
        apiKey: String,
        heliumPaywallDelegate: HeliumPaywallDelegate,
        fallbackPaywall: (any View),
        triggers: [String]? = nil,
        customUserId: String? = nil,
        customAPIEndpoint: String? = nil,
        customUserTraits: HeliumUserTraits? = nil,
        appAttributionToken: UUID? = nil,
        revenueCatAppUserId: String? = nil,
        fallbackBundleURL: URL? = nil,
        fallbackPaywallPerTrigger: [String: any View]? = nil
    ) {
        if initialized {
            return
        }
        initialized = true
        
        if (customUserId != nil) {
            self.overrideUserId(newUserId: customUserId!);
        }
        if (customUserTraits != nil) {
            HeliumIdentityManager.shared.setCustomUserTraits(traits: customUserTraits!);
        }
        
        if let appAttributionToken {
            HeliumIdentityManager.shared.setCustomAppAttributionToken(appAttributionToken)
        } else {
            HeliumIdentityManager.shared.setDefaultAppAttributionToken()
        }
        
        HeliumIdentityManager.shared.revenueCatAppUserId = revenueCatAppUserId
        
        AppReceiptsHelper.shared.setUp()
        
        HeliumFallbackViewManager.shared.setDefaultFallback(fallbackView: AnyView(fallbackPaywall));
        
        // Set up trigger-specific fallback views if provided
        if let triggerFallbacks = fallbackPaywallPerTrigger {
            var triggerToViewMap: [String: AnyView] = [:]
            for (trigger, view) in triggerFallbacks {
                triggerToViewMap[trigger] = AnyView(view)
            }
            HeliumFallbackViewManager.shared.setTriggerToFallback(toSet: triggerToViewMap)
        }
        
        if let fallbackBundleURL {
            HeliumFallbackViewManager.shared.setFallbackBundleURL(fallbackBundleURL)
        }
        
        self.controller = HeliumController(
            apiKey: apiKey
        )
        self.controller?.logInitializeEvent();
        
        HeliumPaywallDelegateWrapper.shared.setDelegate(heliumPaywallDelegate);
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
    
    /// If you need to set a custom appAccountToken for your StoreKit purchases, make sure you keep this value in sync, either in Helium.shared.initialize or with this method.
    /// This helps Helium provide more accurate dashboard metrics.
    public func setAppAttributionToken(_ token: UUID) {
        HeliumIdentityManager.shared.setCustomAppAttributionToken(token)
    }
    
    /// - Parameter url: Pass in a url like "helium-test://helium-test?trigger=trigger_name" or "helium-test://helium-test?puid=paywall_uuid"
    /// - Returns: The result of the purchase.
    @discardableResult
    public func handleDeepLink(_ url: URL?) -> Bool {
        guard let url else {
            return false
        }
        // Only "test paywall" deep links handled at this time.
        guard url.host == "helium-test" else {
            return false
        }
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            print("[Helium] handleDeepLink - Invalid test URL format: \(url)")
            return false
        }
        
        var triggerValue = queryItems.first(where: { $0.name == "trigger" })?.value
        let paywallUUID = queryItems.first(where: { $0.name == "puid" })?.value
        
        if triggerValue == nil && paywallUUID == nil {
            print("[Helium] handleDeepLink - Test URL needs 'trigger' or 'puid': \(url)")
            return false
        }
        
        // Do not show fallbacks... check to see if the needed bundle is available
        if !paywallsLoaded() {
            print("[Helium] handleDeepLink - Helium has not successfully completed initialization.")
            return false
        }
        
        if let paywallUUID, triggerValue == nil {
            triggerValue = HeliumFetchedConfigManager.shared.getTriggerFromPaywallUuid(paywallUUID)
            if triggerValue == nil {
                print("[Helium] handleDeepLink - Could not find trigger for provided paywall UUID: \(paywallUUID).")
            }
        }
        
        guard let trigger = triggerValue else {
            return false
        }
        
        if getPaywallInfo(trigger: trigger) == nil {
            print("[Helium] handleDeepLink - Bundle is not available for this trigger.")
            return false
        }
        
        // hide any existing upsells
        hideAllUpsells()
        
        presentUpsell(trigger: trigger)
        return true
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
        
        let appAccountToken = HeliumIdentityManager.shared.appAttributionToken
        
        let existingTokenOption = newOptions.first { option in
            return String(describing: option).contains("appAccountToken")
        }
        
        if let existingTokenOption {
            let stringDescribingToken = String(describing: existingTokenOption)
            if !stringDescribingToken.contains(appAccountToken.uuidString.lowercased()) && !stringDescribingToken.contains(appAccountToken.uuidString.uppercased()) {
                throw HeliumPurchaseError.appAccountTokenMismatch
            }
        }
        
        newOptions.insert(.appAccountToken(appAccountToken))
        
        return try await purchase(options: newOptions)
    }
}

public enum HeliumPurchaseError: LocalizedError {
    case appAccountTokenMismatch
    
    public var errorDescription: String? {
        switch self {
        case .appAccountTokenMismatch:
            return "If providing appAccountToken, this value MUST match Helium's appAttributionToken, which you can set in initialize or with Helium.shared.setAppAttributionToken()."
        }
    }
}
