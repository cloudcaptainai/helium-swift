import Foundation
import SwiftUI
import StoreKit

struct UpsellViewResult {
    let view: AnyView?
    let isFallback: Bool
    let templateName: String?
}

public class Helium {
    var controller: HeliumController?
    private var baseTemplateViewType: (any BaseTemplateView.Type)?
    private var initialized: Bool = false;
    var fallbackConfig: HeliumFallbackConfig?  // Set during initialize
    
    public static let shared = Helium()
    
    public func presentUpsell(
        trigger: String,
        from viewController: UIViewController? = nil,
        eventHandlers: PaywallEventHandlers? = nil,
        customPaywallTraits: [String: Any]? = nil
    ) {
        if skipPaywallIfNeeded(trigger: trigger) {
            return
        }
        
        // Configure presentation context (always set both to ensure proper reset)
        HeliumPaywallDelegateWrapper.shared.configurePresentationContext(
            eventService: eventHandlers,
            customPaywallTraits: customPaywallTraits
        )
        
        HeliumPaywallPresenter.shared.presentUpsellWithLoadingBudget(trigger: trigger, from: viewController)
    }
    
    func skipPaywallIfNeeded(trigger: String) -> Bool {
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        if paywallInfo?.shouldShow == false {
            HeliumPaywallDelegateWrapper.shared.fireEvent(
                PaywallSkippedEvent(triggerName: trigger)
            )
            return true
        }
        return false
    }
    
    public func loadingStateEnabledFor(trigger: String) -> Bool {
        return fallbackConfig?.useLoadingState(for: trigger) ?? false
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
    
    /// Clears all cached Helium state and allows safe re-initialization.
    ///
    /// **Warning:** This method is intended for debugging, testing, and development scenarios only.
    /// In production apps, configurations should be managed through normal fetch cycles.
    ///
    /// This comprehensive reset will:
    /// - Clear all downloaded bundle files from disk
    /// - Clear fetched paywall configurations from memory
    /// - Clear fallback bundle cache
    /// - Reset download status to `.notDownloadedYet`
    /// - Reset initialization state to allow `initialize()` to be called again
    /// - Clear the controller instance
    /// - Force fallback views to be shown until next successful fetch
    ///
    /// Use cases:
    /// - Testing different configurations
    /// - Switching between environments (staging/production)
    /// - Debugging configuration issues
    /// - Forcing a complete fresh state during development
    ///
    /// After calling this method, you MUST call `initialize()` again before using any
    /// Helium functionality. The SDK will be in an uninitialized state.
    ///
    /// Example:
    /// ```swift
    /// // Clear everything and reinitialize with new config
    /// Helium.shared.clearAllCachedState()
    /// Helium.shared.initialize(
    ///     apiKey: newApiKey,
    ///     fallbackConfig: newFallbackConfig
    /// )
    /// ```
    ///
    /// - Note: This does NOT clear user identification or session data
    public func clearAllCachedState() {
        // Clear physical bundle files from disk
        HeliumAssetManager.shared.clearCache()
        
        // Clear fetched configuration from memory
        HeliumFetchedConfigManager.shared.clearAllFetchedState()
        
        // Completely reset all fallback configurations
        HeliumFallbackViewManager.shared.resetAllFallbacks()
        
        // Reset initialization state to allow re-initialization
        initialized = false
        controller = nil
        fallbackConfig = nil
        baseTemplateViewType = nil
        
        print("[Helium] All cached state cleared and SDK reset. You must call initialize() before using Helium again.")
    }
    
    public func upsellViewForTrigger(trigger: String, eventHandlers: PaywallEventHandlers? = nil, customPaywallTraits: [String: Any]? = nil) -> AnyView? {
        // Configure presentation context (always set both to ensure proper reset)
        HeliumPaywallDelegateWrapper.shared.configurePresentationContext(
            eventService: eventHandlers,
            customPaywallTraits: customPaywallTraits
        )
        
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
                let paywallView = try AnyView(DynamicBaseTemplateView(
                    paywallInfo: templatePaywallInfo,
                    trigger: trigger,
                    resolvedConfig: HeliumFetchedConfigManager.shared.getResolvedConfigJSONForTrigger(trigger)
                ))
                return UpsellViewResult(view: paywallView, isFallback: false, templateName: templatePaywallInfo.paywallTemplateName)
            } catch {
                print("[Helium] Failed to create Helium view wrapper: \(error). Falling back.")
                return fallbackViewFor(trigger: trigger, templateName: templatePaywallInfo.paywallTemplateName)
            }
            
        } else {
            return fallbackViewFor(trigger: trigger, templateName: paywallInfo?.paywallTemplateName)
        }
    }
    
    private func fallbackViewFor(trigger: String, templateName: String?) -> UpsellViewResult {
        var result: AnyView?
        
        let getFallbackViewForTrigger: () -> AnyView? = {
            if let fallbackView = HeliumFallbackViewManager.shared.getFallbackForTrigger(trigger: trigger) {
                return AnyView(HeliumFallbackViewWrapper(trigger: trigger) {
                    fallbackView
                })
            } else {
                return nil
            }
        }
        
        // Check existing fallback mechanisms
        if let fallbackPaywallInfo = HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger) {
            do {
                result = try AnyView(
                    DynamicBaseTemplateView(
                        paywallInfo: fallbackPaywallInfo,
                        trigger: trigger,
                        resolvedConfig: HeliumFallbackViewManager.shared.getResolvedConfigJSONForTrigger(trigger)
                    )
                )
            } catch {
                result = getFallbackViewForTrigger()
            }
        } else {
            result = getFallbackViewForTrigger()
        }
        return UpsellViewResult(view: result, isFallback: true, templateName: templateName)
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
    /// This method sets up the Helium SDK with your API key and configuration. It supports both the modern
    /// `fallbackConfig` approach and deprecated individual fallback parameters for backward compatibility.
    ///
    /// ## Fallback Configuration (Required)
    /// **Important:** You MUST provide at least one fallback mechanism, using EITHER:
    /// - `fallbackConfig` (recommended) - Modern approach with loading states
    /// - OR deprecated parameters (`fallbackPaywall`, `fallbackBundleURL`, `fallbackPaywallPerTrigger`)
    /// 
    /// Initialization will fail with a precondition if no fallback is provided.
    ///
    /// ### Modern Approach (Recommended):
    /// ```swift
    /// Helium.shared.initialize(
    ///     apiKey: "your-api-key",
    ///     heliumPaywallDelegate: myDelegate,
    ///     fallbackConfig: .withFallbackBundle(
    ///         Bundle.main.url(forResource: "fallback-bundle", withExtension: "json")!,
    ///         loadingBudget: 3.0
    ///     )
    /// )
    /// ```
    ///
    /// ### Loading States
    /// When using `fallbackConfig`, you can control loading behavior:
    /// - `useLoadingState`: Show a loading view while fetching paywalls (default: true)
    /// - `loadingBudget`: Maximum seconds to show loading before fallback (default: 2.0)
    /// - `loadingView`: Custom loading view or nil for default shimmer animation
    ///
    /// ### Fallback Priority
    /// When paywalls cannot be fetched, fallbacks are shown in this order:
    /// 1. **Fallback bundle** - If trigger exists in bundle JSON
    /// 2. **Per-trigger fallback views** - From `fallbackPerTrigger` dictionary
    /// 3. **Global fallback view** - From `fallbackView`
    ///
    /// - Parameters:
    ///   - apiKey: Your Helium API key from the dashboard
    ///   - heliumPaywallDelegate: Delegate for paywall events and purchases. Defaults to StoreKitDelegate if nil
    ///   - fallbackPaywall: **Deprecated** - Use `fallbackConfig` instead. Global fallback view
    ///   - fallbackConfig: **Recommended** - Comprehensive fallback and loading configuration
    ///   - triggers: Optional array of trigger names to prefetch
    ///   - customUserId: Override the auto-generated user ID
    ///   - customAPIEndpoint: Custom API endpoint for development/testing
    ///   - customUserTraits: User attributes for targeting and personalization
    ///   - appAttributionToken: Custom appAccountToken for StoreKit purchases
    ///   - revenueCatAppUserId: User ID for RevenueCat integration
    ///   - fallbackBundleURL: **Deprecated** - Use `fallbackConfig` instead
    ///   - fallbackPaywallPerTrigger: **Deprecated** - Use `fallbackConfig` instead
    ///
    /// - Note: Deprecated parameters disable loading states for backward compatibility
    /// - Warning: Mixing `fallbackConfig` with deprecated parameters causes a fatal error
    ///
    @available(iOS 15.0, *)
    public func initialize(
        apiKey: String,
        heliumPaywallDelegate: HeliumPaywallDelegate? = nil,
        fallbackPaywall: (any View)? = nil,
        fallbackConfig: HeliumFallbackConfig? = nil,
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
        
        // Validate that only one fallback approach is used
        let hasDeprecatedParams = fallbackPaywall != nil || fallbackBundleURL != nil || fallbackPaywallPerTrigger != nil
        let hasNewConfig = fallbackConfig != nil
        
        precondition(
            !(hasDeprecatedParams && hasNewConfig),
            """
            Helium initialization error: Cannot use both fallbackConfig and deprecated fallback parameters simultaneously.
            Please use either:
            - fallbackConfig (recommended) for new implementations
            - OR fallbackPaywall/fallbackBundleURL/fallbackPaywallPerTrigger (deprecated) for backward compatibility
            But not both.
            """
        )
        
        // Determine the fallback configuration to use
        let finalFallbackConfig: HeliumFallbackConfig?
        
        if let providedConfig = fallbackConfig {
            // Use the new fallbackConfig if provided
            finalFallbackConfig = providedConfig
        } else if hasDeprecatedParams {
            // Create a HeliumFallbackConfig from the deprecated parameters
            if let triggerFallbacks = fallbackPaywallPerTrigger, let bundleURL = fallbackBundleURL {
                // Both per-trigger and bundle
                finalFallbackConfig = HeliumFallbackConfig.withMultipleFallbacks(
                    fallbackView: fallbackPaywall,
                    fallbackPerTrigger: triggerFallbacks,
                    fallbackBundle: bundleURL,
                    useLoadingState: false  // Maintain old behavior - no loading state
                )
            } else if let triggerFallbacks = fallbackPaywallPerTrigger {
                // Only per-trigger fallbacks
                finalFallbackConfig = HeliumFallbackConfig.withMultipleFallbacks(
                    fallbackView: fallbackPaywall,
                    fallbackPerTrigger: triggerFallbacks,
                    fallbackBundle: nil,
                    useLoadingState: false
                )
            } else if let bundleURL = fallbackBundleURL {
                // Only bundle URL
                finalFallbackConfig = HeliumFallbackConfig.withMultipleFallbacks(
                    fallbackView: fallbackPaywall,
                    fallbackPerTrigger: nil,
                    fallbackBundle: bundleURL,
                    useLoadingState: false
                )
            } else if let fallback = fallbackPaywall {
                // Only default fallback
                finalFallbackConfig = HeliumFallbackConfig.withFallbackView(fallback, useLoadingState: false)
            } else {
                finalFallbackConfig = nil
            }
        } else {
            // No fallback configuration provided
            finalFallbackConfig = nil
        }
        
        // Store the final fallback configuration
        self.fallbackConfig = finalFallbackConfig
        
        // Validate that at least some fallback is configured
        precondition(
            finalFallbackConfig != nil,
            """
            Helium initialization error: No fallback configuration provided!
            
            We weren't able to get a fallback paywall! Please configure fallbacks by going to https://docs.tryhelium.com/guides/fallback-bundle to get set up.
            
            You must provide at least one of the following:
            - fallbackConfig (recommended): Use HeliumFallbackConfig.withFallbackBundle(), .withFallbackView(), etc.
            - fallbackPaywall (deprecated): A default SwiftUI view
            - fallbackBundleURL (deprecated): URL to a fallback bundle JSON
            - fallbackPaywallPerTrigger (deprecated): Trigger-specific fallback views
            """
        )
        
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
        
        if let revenueCatAppUserId {
            HeliumIdentityManager.shared.setRevenueCatAppUserId(revenueCatAppUserId)
        }
        
        AppReceiptsHelper.shared.setUp()
        
        // Set up fallback view if provided
        if let fallbackView = finalFallbackConfig?.fallbackView {
            HeliumFallbackViewManager.shared.setDefaultFallback(fallbackView: fallbackView);
        } else if fallbackPaywall != nil {
            // Handle deprecated fallbackPaywall parameter directly
            HeliumFallbackViewManager.shared.setDefaultFallback(fallbackView: AnyView(fallbackPaywall!));
        }
        
        // Set up trigger-specific fallback views if provided
        if let triggerFallbacks = finalFallbackConfig?.fallbackPerTrigger {
            HeliumFallbackViewManager.shared.setTriggerToFallback(toSet: triggerFallbacks)
        } else if let triggerFallbacks = fallbackPaywallPerTrigger {
            // Handle deprecated fallbackPaywallPerTrigger parameter directly
            var triggerToViewMap: [String: AnyView] = [:]
            for (trigger, view) in triggerFallbacks {
                triggerToViewMap[trigger] = AnyView(view)
            }
            HeliumFallbackViewManager.shared.setTriggerToFallback(toSet: triggerToViewMap)
        }
        
        // Set up fallback bundle if provided
        if let fallbackBundleURL = finalFallbackConfig?.fallbackBundle {
            HeliumFallbackViewManager.shared.setFallbackBundleURL(fallbackBundleURL)
        } else if let bundleURL = fallbackBundleURL {
            // Handle deprecated fallbackBundleURL parameter directly
            HeliumFallbackViewManager.shared.setFallbackBundleURL(bundleURL)
        }
        
        self.controller = HeliumController(
            apiKey: apiKey
        )
        self.controller?.logInitializeEvent();
        
        // Use provided delegate or default to StoreKitDelegate
        let delegate = heliumPaywallDelegate ?? StoreKitDelegate()
        HeliumPaywallDelegateWrapper.shared.setDelegate(delegate);
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
    
    /// If using RevenueCat for purchases, let Helium know the latest RevenueCat appUserId value for more accurate metrics.
    /// Note - You DO NOT have to set this if using Helium's RevenueCatPurchaseDelegate.
    public func setRevenueCatAppUserId(_ rcAppUserId: String) {
        HeliumIdentityManager.shared.setRevenueCatAppUserId(rcAppUserId)
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
