import Foundation
import SwiftUI
import StoreKit

struct UpsellViewResult {
    let view: AnyView?
    let fallbackReason: PaywallUnavailableReason?
    let templateName: String?
    
    var isFallback: Bool {
        fallbackReason != nil
    }
}

public class Helium {
    var controller: HeliumController?
    private var baseTemplateViewType: (any BaseTemplateView.Type)?
    private var initialized: Bool = false;
    var fallbackConfig: HeliumFallbackConfig?  // Set during initialize
    
    private(set) var lightDarkModeOverride: HeliumLightDarkMode = .system
    
    private func reset() {
        initialized = false
        controller = nil
        fallbackConfig = nil
        baseTemplateViewType = nil
        lightDarkModeOverride = .system
    }
    
    public static let shared = Helium()
    public static let restorePurchaseConfig = RestorePurchaseConfig()
    
    public func presentUpsell(
        trigger: String,
        from viewController: UIViewController? = nil,
        eventHandlers: PaywallEventHandlers? = nil,
        customPaywallTraits: [String: Any]? = nil,
        dontShowIfAlreadyEntitled: Bool = false
    ) {
        if skipPaywallIfNeeded(trigger: trigger) {
            return
        }
        
        // Configure presentation context (always set both to ensure proper reset)
        HeliumPaywallDelegateWrapper.shared.configurePresentationContext(
            eventService: eventHandlers,
            customPaywallTraits: customPaywallTraits,
            dontShowIfAlreadyEntitled: dontShowIfAlreadyEntitled
        )
        
        HeliumPaywallPresenter.shared.presentUpsellWithLoadingBudget(trigger: trigger, from: viewController)
    }
    
    func skipPaywallIfNeeded(trigger: String) -> Bool {
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        if paywallInfo?.shouldShow == false {
            // Fire allocation event even when paywall is skipped
            ExperimentAllocationTracker.shared.trackAllocationIfNeeded(
                trigger: trigger,
                isFallback: false
            )
            
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
    
    /// Returns experiment allocation info for all configured triggers
    /// 
    /// - Returns: Dictionary mapping trigger names to their experiment info, or nil if:
    ///   - Helium hasn't been initialized
    ///   - Config hasn't been fetched
    ///   - No triggers have experiments
    ///
    /// ## Example Usage
    /// ```swift
    /// // Get all experiment info
    /// if let allExperiments = Helium.shared.getHeliumExperimentInfo() {
    ///     for (trigger, info) in allExperiments {
    ///         print("Trigger: \(trigger)")
    ///         print("Experiment: \(info.experimentName ?? "unknown")")
    ///         print("Variant: \(info.chosenVariantDetails?.allocationIndex ?? 0)")
    ///     }
    /// }
    ///
    /// // Get specific trigger's experiment info
    /// if let onboardingInfo = Helium.shared.getHeliumExperimentInfo()?["onboarding"] {
    ///     print("Onboarding variant: \(onboardingInfo.chosenVariantDetails?.allocationIndex ?? 0)")
    /// }
    /// ```
    ///
    /// - SeeAlso: `ExperimentInfo`, `VariantDetails`, `HashDetails`
    public func getHeliumExperimentInfo() -> [String: ExperimentInfo]? {
        guard HeliumFetchedConfigManager.shared.getConfig() != nil else {
            return nil
        }
        
        let triggers = HeliumFetchedConfigManager.shared.getFetchedTriggerNames()
        var experimentInfoMap: [String: ExperimentInfo] = [:]
        
        for trigger in triggers {
            if let experimentInfo = getExperimentInfoForTrigger(trigger) {
                experimentInfoMap[trigger] = experimentInfo
            }
        }
        
        return experimentInfoMap.isEmpty ? nil : experimentInfoMap
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
        hideAllUpsells()
        
        // Clear physical bundle files from disk
        HeliumAssetManager.shared.clearCache()
        
        // Clear fetched configuration from memory
        HeliumFetchedConfigManager.reset()
        
        // Completely reset all fallback configurations
        HeliumFallbackViewManager.reset()
        
        // Reset experiment allocation tracking
        ExperimentAllocationTracker.shared.reset()
        
        // Reset initialization state to allow re-initialization
        reset()
                
        print("[Helium] All cached state cleared and SDK reset. You must call initialize() before using Helium again.")
    }
    
    public func upsellViewForTrigger(trigger: String, eventHandlers: PaywallEventHandlers? = nil, customPaywallTraits: [String: Any]? = nil) -> AnyView? {
        let upsellView = upsellViewResultFor(trigger: trigger).view
        
        if upsellView != nil {
            // Configure presentation context (always set both to ensure proper reset)
            HeliumPaywallDelegateWrapper.shared.configurePresentationContext(
                eventService: eventHandlers,
                customPaywallTraits: customPaywallTraits
            )
        }
        
        return upsellView
    }
    
    func upsellViewResultFor(trigger: String) -> UpsellViewResult {
        if !initialized {
            print("[Helium] Helium.shared.initialize() needs to be called before presenting a paywall. Please visit docs.tryhelium.com or message founders@tryhelium.com to get set up!")
            return UpsellViewResult(view: nil, fallbackReason: .notInitialized, templateName: nil)
        }
        
        
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        if paywallsLoaded() && HeliumFetchedConfigManager.shared.hasBundles() {
            
            guard let templatePaywallInfo = paywallInfo else {
                return fallbackViewFor(trigger: trigger, templateName: nil, fallbackReason: .triggerHasNoPaywall)
            }
            if templatePaywallInfo.forceShowFallback == true {
                return fallbackViewFor(trigger: trigger, templateName: templatePaywallInfo.paywallTemplateName, fallbackReason: .forceShowFallback)
            }
            
            do {
                let paywallView = try AnyView(DynamicBaseTemplateView(
                    paywallInfo: templatePaywallInfo,
                    trigger: trigger,
                    fallbackReason: nil,
                    resolvedConfig: HeliumFetchedConfigManager.shared.getResolvedConfigJSONForTrigger(trigger),
                    backupResolvedConfig: HeliumFallbackViewManager.shared.getResolvedConfigJSONForTrigger(trigger)
                ))
                return UpsellViewResult(view: paywallView, fallbackReason: nil, templateName: templatePaywallInfo.paywallTemplateName)
            } catch {
                print("[Helium] Failed to create Helium view wrapper: \(error). Falling back.")
                return fallbackViewFor(trigger: trigger, templateName: templatePaywallInfo.paywallTemplateName, fallbackReason: .invalidResolvedConfig)
            }
            
        } else {
            let fallbackReason: PaywallUnavailableReason
            switch HeliumFetchedConfigManager.shared.downloadStatus {
            case .notDownloadedYet:
                fallbackReason = .paywallsNotDownloaded
            case .inProgress:
                switch HeliumFetchedConfigManager.shared.downloadStep {
                case .config:
                    fallbackReason = .configFetchInProgress
                case .bundles:
                    fallbackReason = .bundlesFetchInProgress
                case .products:
                    fallbackReason = .productsFetchInProgress
                }
            case .downloadSuccess:
                fallbackReason = .paywallBundlesMissing
            case .downloadFailure:
                fallbackReason = .paywallsDownloadFail
            }
            return fallbackViewFor(trigger: trigger, templateName: paywallInfo?.paywallTemplateName, fallbackReason: fallbackReason)
        }
    }
    
    private func fallbackViewFor(trigger: String, templateName: String?, fallbackReason: PaywallUnavailableReason) -> UpsellViewResult {
        var result: AnyView?
        
        let getFallbackViewForTrigger: () -> AnyView? = {
            if let fallbackView = HeliumFallbackViewManager.shared.getFallbackForTrigger(trigger: trigger) {
                return AnyView(HeliumFallbackViewWrapper(trigger: trigger, fallbackReason: fallbackReason) {
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
                        fallbackReason: fallbackReason,
                        resolvedConfig: HeliumFallbackViewManager.shared.getResolvedConfigJSONForTrigger(trigger)
                    )
                )
            } catch {
                result = getFallbackViewForTrigger()
            }
        } else {
            result = getFallbackViewForTrigger()
        }
        return UpsellViewResult(view: result, fallbackReason: fallbackReason, templateName: templateName)
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
    
    public func canShowPaywallFor(trigger: String) -> CanShowPaywallResult {
        let upsellResult = upsellViewResultFor(trigger: trigger)
        let canShow = upsellResult.view != nil
        return CanShowPaywallResult(
            canShow: canShow,
            isFallback: canShow ? upsellResult.isFallback : nil,
            paywallUnavailableReason: upsellResult.fallbackReason
        )
    }
    
    /// Get experiment allocation info for a specific trigger
    /// 
    /// - Parameter trigger: The trigger name to get experiment info for
    /// - Returns: ExperimentInfo if the trigger has experiment data, nil otherwise
    ///
    /// ## Example Usage
    /// ```swift
    /// if let experimentInfo = Helium.shared.getExperimentInfoForTrigger("onboarding") {
    ///     print("Experiment: \(experimentInfo.experimentName ?? "unknown")")
    ///     print("Variant: \(experimentInfo.chosenVariantDetails?.allocationIndex ?? 0)")
    /// }
    /// ```
    ///
    /// - SeeAlso: `ExperimentInfo`, `getHeliumExperimentInfo()`
    public func getExperimentInfoForTrigger(_ trigger: String) -> ExperimentInfo? {
        guard let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger) else {
            return nil
        }
        
        return paywallInfo.extractExperimentInfo(trigger: trigger)
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
            finalFallbackConfig = HeliumFallbackConfig.withMultipleFallbacks(
                fallbackView: fallbackPaywall,
                fallbackPerTrigger: fallbackPaywallPerTrigger,
                fallbackBundle: fallbackBundleURL
            )
        } else {
            // No fallback configuration provided; should not be possible!
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
        
        Task {
            await WebViewManager.shared.preCreateFirstWebView()
            
            await HeliumEntitlementsManager.shared.configure()
        }
    }
    
    func isInitialized() -> Bool {
        return initialized
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
    
    /// Sets the light/dark mode override for Helium paywalls.
    /// - Parameter mode: The desired appearance mode (.light, .dark, or .system)
    /// - Note: .system respects the device's current appearance setting (default)
    public func setLightDarkModeOverride(_ mode: HeliumLightDarkMode) {
        lightDarkModeOverride = mode
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
    
    // MARK: - Entitlements / Subscription Status
    
    /// Checks if the user has an active entitlement for any product attached to the paywall that will show for provided trigger.
    /// - Parameter trigger: Trigger that would be used to show the paywall.
    /// - Parameter considerAssociatedSubscriptions: If true, look at subscription groups associated with products in the paywall, otherwise just look at exact products in the paywall.
    /// - Returns: `true` if the user has bought one of the products on the paywall or is actively subscribed to a subscription group that includes one of the products. `false` if not. Returns `nil` if not known (i.e. the paywall is not downloaded yet).
    public func hasEntitlementForPaywall(
        trigger: String,
        considerAssociatedSubscriptions: Bool = false
    ) async -> Bool? {
        return await HeliumEntitlementsManager.shared.hasEntitlementForPaywall(trigger: trigger, considerAssociatedSubscriptions: considerAssociatedSubscriptions)
    }
    
    /// Checks if the user has any active subscription (auto-renewable or optionally non-renewing).
    /// - Parameter includeNonRenewing: Whether to include non-renewing subscriptions in the check (default: true)
    /// - Returns: `true` if the user has at least one active subscription, `false` otherwise
    public func hasAnyActiveSubscription(includeNonRenewing: Bool = true) async -> Bool {
        return await HeliumEntitlementsManager.shared.hasAnyActiveSubscription(includeNonRenewing: includeNonRenewing)
    }
    
    /// Checks if the user has any entitlement (any non-consumable purchase or subscription).
    /// - Returns: `true` if the user has at least one entitlement, `false` otherwise
    /// - Note: This method does not include consumable purchases
    public func hasAnyEntitlement() async -> Bool {
        return await HeliumEntitlementsManager.shared.hasAnyEntitlement()
    }
    
    /// Checks if the user has entitlement for this product (any non-consumable purchase or subscription).
    /// - Parameter productId: The product ID to check
    /// - Returns: `true` if the user has an active entitlement for the product, `false` otherwise
    /// - Note: This method does not work for consumable purchases
    public func hasActiveEntitlementFor(productId: String) async -> Bool {
        return await HeliumEntitlementsManager.shared.hasActiveEntitlementFor(productId: productId)
    }
    
    /// Checks if the user has an active subscription for a specific product.
    /// - Parameter productId: The product ID to check
    /// - Returns: `true` if the user has an active subscription for the product, `false` otherwise
    public func hasActiveSubscriptionFor(productId: String) async -> Bool {
        return await HeliumEntitlementsManager.shared.hasActiveSubscriptionFor(productId: productId)
    }
    
    /// Checks if the user has an active entitlement for a specific subscription group.
    /// - Parameter subscriptionGroupID: The subscription group ID to check
    /// - Returns: `true` if the user has an active subscription in the specified group, `false` otherwise
    public func hasActiveSubscriptionFor(subscriptionGroupID: String) async -> Bool {
        return await HeliumEntitlementsManager.shared.hasActiveSubscriptionFor(subscriptionGroupID: subscriptionGroupID)
    }
    
    /// Returns a dictionary of all active auto-renewable subscriptions with their current subscription info.
    /// - Returns: Dictionary mapping product IDs to their subscription info
    public func activeSubscriptions() async -> [String: Product.SubscriptionInfo] {
        return await HeliumEntitlementsManager.shared.activeSubscriptions()
    }
    
    /// Returns an array of all purchased product IDs that the user currently has access to.
    /// - Returns: Array of product ID strings for all current entitlements
    /// - Note: This method does not include consumable purchases
    public func purchasedProductIds() async -> [String] {
        return await HeliumEntitlementsManager.shared.purchasedProductIds()
    }
    
    /// Gets the subscription status for a specific subscription group.
    /// - Parameter subscriptionGroupID: The subscription group ID to check
    /// - Returns: The subscription status if found, `nil` otherwise
    public func subscriptionStatusFor(subscriptionGroupID: String) async -> Product.SubscriptionInfo.Status? {
        return await HeliumEntitlementsManager.shared.subscriptionStatusFor(subscriptionGroupID: subscriptionGroupID)
    }
    
    /// Gets the subscription status for a specific product.
    /// - Parameter productId: The product ID to check
    /// - Returns: The subscription status if found, `nil` otherwise
    public func subscriptionStatusFor(productId: String) async -> Product.SubscriptionInfo.Status? {
        return await HeliumEntitlementsManager.shared.subscriptionStatusFor(productId: productId)
    }
    
    /// Reset Helium entirely so you can call initialize again. Only for advanced use cases.
    public static func resetHelium(clearUserTraits: Bool = true) {
        HeliumPaywallPresenter.shared.hideAllUpsells()
        
        HeliumPaywallDelegateWrapper.reset()
        
        // Clear fetched configuration from memory
        HeliumFetchedConfigManager.reset()
        
        // Completely reset all fallback configurations
        HeliumFallbackViewManager.reset()
        
        // Reset experiment allocation tracking
        ExperimentAllocationTracker.shared.reset()
        
        restorePurchaseConfig.reset()
        
        HeliumIdentityManager.reset(clearUserTraits: clearUserTraits)
        
        Helium.shared.reset()
        
        // NOTE - not clearing entitlements nor products cache nor transactions caches nor cached bundles
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
