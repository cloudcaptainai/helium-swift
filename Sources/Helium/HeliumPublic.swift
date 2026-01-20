import Foundation
import SwiftUI
import StoreKit

struct PaywallViewResult {
    let viewAndSession: PaywallViewAndSession?
    let fallbackReason: PaywallUnavailableReason?
    
    var isFallback: Bool {
        fallbackReason != nil
    }
}
struct PaywallViewAndSession {
    let view: AnyView
    let paywallSession: PaywallSession
}

public struct PaywallPresentationConfig {
    // View controller to present from. Defaults to current top view controller
    var presentFromViewController: UIViewController? = nil
    // Custom traits to send to the paywall
    var customPaywallTraits: [String: Any]? = nil
    // Don't show paywall if user is entitled to a product in paywall
    var dontShowIfAlreadyEntitled: Bool = true
    // How long to allow loading state before switching to fallback logic.
    // Use zero or negative value to disable loading state.
    var loadingBudget: TimeInterval = HeliumConfig.defaultLoadingBudget
    
    public init(
        presentFromViewController: UIViewController? = nil,
        customPaywallTraits: [String: Any]? = nil,
        dontShowIfAlreadyEntitled: Bool = true,
        loadingBudget: TimeInterval = HeliumConfig.defaultLoadingBudget
    ) {
        self.presentFromViewController = presentFromViewController
        self.customPaywallTraits = customPaywallTraits
        self.dontShowIfAlreadyEntitled = dontShowIfAlreadyEntitled
        self.loadingBudget = loadingBudget
    }
}

public class Helium {
    var controller: HeliumController?
    private var initialized: Bool = false;
    
    private(set) var lightDarkModeOverride: HeliumLightDarkMode = .system
    
    private func reset() {
        initialized = false
        controller = nil
        lightDarkModeOverride = .system
    }
    
    public static let shared = Helium()
    public static let restorePurchaseConfig = RestorePurchaseConfig()
    public static let identify = HeliumIdentify()
    public static let config = HeliumConfig()
    
    public func presentPaywall(
        trigger: String,
        config: PaywallPresentationConfig = PaywallPresentationConfig(),
        eventHandlers: PaywallEventHandlers? = nil,
        onEntitled: (() -> Void)? = nil,
        onPaywallNotShown: @escaping (PaywallNotShownReason) -> Void
    ) {
        if skipPaywallIfNeeded(trigger: trigger) {
            return
        }
        
        // Configure presentation context (always set both to ensure proper reset)
        HeliumPaywallDelegateWrapper.shared.configurePresentationContext(
            paywallPresentationConfig: config,
            eventService: eventHandlers,
            onEntitledHandler: onEntitled,
            onPaywallNotShown: onPaywallNotShown
        )
        
        HeliumPaywallPresenter.shared.presentUpsellWithLoadingBudget(trigger: trigger, config: config)
    }
    
    func skipPaywallIfNeeded(trigger: String) -> Bool {
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        if paywallInfo?.shouldShow == false {
            // Fire allocation event even when paywall is skipped
            ExperimentAllocationTracker.shared.trackAllocationIfNeeded(
                trigger: trigger,
                isFallback: false,
                paywallSession: nil
            )
            
            HeliumPaywallDelegateWrapper.shared.fireEvent(
                PaywallSkippedEvent(triggerName: trigger),
                paywallSession: nil
            )
            return true
        }
        return false
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
        
        return experimentInfoMap
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
        
        HeliumEventListeners.shared.removeAllListeners()
        
        // Reset initialization state to allow re-initialization
        reset()
                
        print("[Helium] All cached state cleared and SDK reset. You must call initialize() before using Helium again.")
    }
    
    public func upsellViewForTrigger(trigger: String, eventHandlers: PaywallEventHandlers? = nil, customPaywallTraits: [String: Any]? = nil) -> AnyView? {
        let upsellView = upsellViewResultFor(trigger: trigger).viewAndSession?.view
        
        if upsellView != nil {
            // Configure presentation context (always set both to ensure proper reset)
            HeliumPaywallDelegateWrapper.shared.configurePresentationContext(
                paywallPresentationConfig: PaywallPresentationConfig(),
                eventService: eventHandlers,
                onEntitledHandler: nil
            )
        }
        
        return upsellView
    }
    
    func upsellViewResultFor(trigger: String) -> PaywallViewResult {
        if !initialized {
            print("[Helium] Helium.shared.initialize() needs to be called before presenting a paywall. Please visit docs.tryhelium.com or message founders@tryhelium.com to get set up!")
            return PaywallViewResult(viewAndSession: nil, fallbackReason: .notInitialized)
        }
        
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        if paywallsLoaded() && HeliumFetchedConfigManager.shared.hasBundles() {
            guard let templatePaywallInfo = paywallInfo else {
                return fallbackViewFor(trigger: trigger, paywallInfo: nil, fallbackReason: .triggerHasNoPaywall)
            }
            if templatePaywallInfo.forceShowFallback == true {
                return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: .forceShowFallback)
            }
            
            if let bundleSkip = HeliumFetchedConfigManager.shared.triggersWithSkippedBundleAndReason.first(where: { $0.trigger == trigger }) {
                return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: bundleSkip.reason)
            }
            
            do {
                guard let filePath = templatePaywallInfo.localBundlePath else {
                    return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: .couldNotFindBundleUrl)
                }
                let backupFilePath = HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger)?.localBundlePath
                
                let paywallSession = PaywallSession(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackType: .notFallback)
                
                let paywallView = try AnyView(DynamicBaseTemplateView(
                    paywallSession: paywallSession,
                    fallbackReason: nil,
                    filePath: filePath,
                    backupFilePath: backupFilePath,
                    resolvedConfig: HeliumFetchedConfigManager.shared.getResolvedConfigJSONForTrigger(trigger)
                ))
                return PaywallViewResult(viewAndSession: PaywallViewAndSession(view: paywallView, paywallSession: paywallSession), fallbackReason: nil)
            } catch {
                print("[Helium] Failed to create Helium view wrapper: \(error). Falling back.")
                return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: .invalidResolvedConfig)
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
            return fallbackViewFor(trigger: trigger, paywallInfo: paywallInfo, fallbackReason: fallbackReason)
        }
    }
    
    private func fallbackViewFor(trigger: String, paywallInfo: HeliumPaywallInfo?, fallbackReason: PaywallUnavailableReason) -> PaywallViewResult {
        var result: AnyView?
        
        let fallbackViewPaywallSession = PaywallSession(trigger: trigger, paywallInfo: paywallInfo, fallbackType: .fallbackView)
        let getFallbackViewForTrigger: () -> AnyView? = {
            if let fallbackView = HeliumFallbackViewManager.shared.getFallbackForTrigger(trigger: trigger) {
                return AnyView(HeliumFallbackViewWrapper(trigger: trigger, paywallSession: fallbackViewPaywallSession, fallbackReason: fallbackReason) {
                    fallbackView
                })
            } else {
                return nil
            }
        }
        
        // Check existing fallback mechanisms
        if let fallbackPaywallInfo = HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger),
           let filePath = fallbackPaywallInfo.localBundlePath {
            do {
                let fallbackBundlePaywallSession = PaywallSession(trigger: trigger, paywallInfo: fallbackPaywallInfo, fallbackType: .fallbackBundle)
                let fallbackBundleView = try AnyView(
                    DynamicBaseTemplateView(
                        paywallSession: fallbackBundlePaywallSession,
                        fallbackReason: fallbackReason,
                        filePath: filePath,
                        backupFilePath: nil,
                        resolvedConfig: HeliumFallbackViewManager.shared.getResolvedConfigJSONForTrigger(trigger)
                    )
                )
                return PaywallViewResult(viewAndSession: PaywallViewAndSession(view: fallbackBundleView, paywallSession: fallbackBundlePaywallSession), fallbackReason: fallbackReason)
            } catch {
                result = getFallbackViewForTrigger()
            }
        } else {
            result = getFallbackViewForTrigger()
        }
        guard let result else {
            return PaywallViewResult(viewAndSession: nil, fallbackReason: fallbackReason)
        }
        return PaywallViewResult(viewAndSession: PaywallViewAndSession(view: result, paywallSession: fallbackViewPaywallSession), fallbackReason: fallbackReason)
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
        if !paywallsLoaded() {
            return nil
        }
        guard let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger) else {
            return nil
        }
        return PaywallInfo(paywallTemplateName: paywallInfo.paywallTemplateName, shouldShow: paywallInfo.shouldShow ?? true)
    }
    
    public func canShowPaywallFor(trigger: String) -> CanShowPaywallResult {
        let upsellResult = upsellViewResultFor(trigger: trigger)
        let canShow = upsellResult.viewAndSession?.view != nil
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
        return HeliumFetchedConfigManager.shared.extractExperimentInfo(trigger: trigger)
    }
    
    /// Get all experiments this user has already been enrolled in, for which the experiment is running.
    ///
    /// Returns experiments that:
    /// - User has hit the trigger and been allocated
    /// - Experiment is currently running
    ///
    /// - Returns: Array of ExperimentInfo for active enrollments, or nil if there was an issue (e.g., SDK not initialized)
    ///
    /// ## Example Usage
    /// ```swift
    /// if let activeExperiments = Helium.shared.enrolledExperiments() {
    ///     for experiment in activeExperiments {
    ///         print("Active: \(experiment.trigger) - \(experiment.experimentName ?? "unknown")")
    ///         print("Enrolled at: \(experiment.enrolledAt?.description ?? "unknown")")
    ///         print("Variant: \(experiment.chosenVariantDetails?.allocationName ?? "unknown")")
    ///     }
    /// }
    /// ```
    /// - SeeAlso: `allExperiments()`, `ExperimentInfo`, `ExperimentEnrollmentStatus`
    public func enrolledExperiments() -> [ExperimentInfo]? {
        guard HeliumFetchedConfigManager.shared.getConfig() != nil else {
            return nil
        }
        
        let triggers = HeliumFetchedConfigManager.shared.getFetchedTriggerNames()
        var activeExperiments: [ExperimentInfo] = []
        
        for trigger in triggers {
            if let experimentInfo = getExperimentInfoForTrigger(trigger),
               experimentInfo.enrollmentStatus == .activeEnrollment {
                if experimentInfo.enrolledTrigger == trigger {
                    // favor experiment with trigger where actually enrolled
                    // although technically they should be the same exact experiment data
                    activeExperiments.removeAll { $0.experimentId == experimentInfo.experimentId }
                }
                if !activeExperiments.contains(where: { $0.experimentId == experimentInfo.experimentId }) {
                    activeExperiments.append(experimentInfo)
                }
            }
        }
        
        return activeExperiments
    }
    
    /// Get all experiment info for this user (both predicted and active enrollments).
    ///
    /// - Returns: Array of all ExperimentInfo (predicted + active), or nil if there was an issue (e.g., SDK not initialized)
    ///
    /// ## Example Usage
    /// ```swift
    /// if let allExperiments = Helium.shared.allExperiments() {
    ///     for experiment in allExperiments {
    ///         print("\(experiment.trigger): \(experiment.enrollmentStatus)")
    ///         if experiment.enrollmentStatus == .activeEnrollment {
    ///             print("  Enrolled at: \(experiment.enrolledAt?.description ?? "unknown")")
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// - SeeAlso: `enrolledExperiments()`, `ExperimentInfo`, `ExperimentEnrollmentStatus`
    public func allExperiments() -> [ExperimentInfo]? {
        guard HeliumFetchedConfigManager.shared.getConfig() != nil else {
            return nil
        }
        
        let triggers = HeliumFetchedConfigManager.shared.getFetchedTriggerNames()
        var allExperiments: [ExperimentInfo] = []
        
        for trigger in triggers {
            if let experimentInfo = getExperimentInfoForTrigger(trigger),
               experimentInfo.experimentId != nil && !experimentInfo.experimentId!.isEmpty {
                if experimentInfo.enrolledTrigger == trigger {
                    // favor experiment with trigger where actually enrolled
                    // although technically they should be the same exact experiment data
                    allExperiments.removeAll { $0.experimentId == experimentInfo.experimentId }
                }
                if !allExperiments.contains(where: { $0.experimentId == experimentInfo.experimentId }) {
                    allExperiments.append(experimentInfo)
                }
            }
        }
        
        return allExperiments
    }
    
    /// Initializes the Helium paywall system.
    /// - Set up user identification using Helium.identify, ideally before calling initialize().
    /// - Adjust Helium configuration using Helium.config, ideally before calling initialize().
    /// - Initialize as early as possible in your app’s lifecycle
    /// - Latest docs at https://docs.tryhelium.com/sdk/quickstart-ios
    ///
    /// - Parameters:
    ///   - apiKey: Your Helium API key from the dashboard
    ///
    @available(iOS 15.0, *)
    public func initialize(
        apiKey: String
    ) {
        if initialized {
            return
        }
        initialized = true
        
        // Start store country code fetch immediately
        _ = AppStoreCountryHelper.shared
        
        AppReceiptsHelper.shared.setUp()
        
        HeliumFallbackViewManager.shared.setUpFallbackBundle()
        
        HeliumSdkConfig.shared.setInitializeConfig(
            purchaseDelegate: Helium.config.purchaseDelegate.delegateType,
            customAPIEndpoint: Helium.config.customAPIEndpoint
        )
        
        self.controller = HeliumController(
            apiKey: apiKey
        )
        self.controller?.logInitializeEvent()
        self.controller?.downloadConfig()
        
        Task {
            await WebViewManager.shared.preCreateFirstWebView()
            
            await HeliumEntitlementsManager.shared.configure()
            await HeliumTransactionManager.shared.configure()
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
    
    /// Add a listener for all Helium events. Listeners are stored weakly, so if you create a listener inline it may not be retained.
    public func addHeliumEventListener(_ listener: HeliumEventListener) {
        HeliumEventListeners.shared.addListener(listener)
    }
    
    /// Remove a specific Helium event listener.
    public func removeHeliumEventListener(_ listener: HeliumEventListener) {
        HeliumEventListeners.shared.removeListener(listener)
    }
    
    /// Remove all Helium event listeners.
    public func removeAllHeliumEventListeners() {
        HeliumEventListeners.shared.removeAllListeners()
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
        
        presentPaywall(trigger: trigger) { reason in
            print("[Helium] handleDeepLink - Could not show paywall. \(reason)")
        }
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
    public static func resetHelium(clearUserTraits: Bool = true, clearExperimentAllocations: Bool = false) {
        HeliumPaywallPresenter.shared.hideAllUpsells()
        
        HeliumPaywallDelegateWrapper.reset()
        
        // Clear fetched configuration from memory
        HeliumFetchedConfigManager.reset()
        
        // Completely reset all fallback configurations
        HeliumFallbackViewManager.reset()
        
        if clearExperimentAllocations {
            ExperimentAllocationTracker.shared.reset()
        }
        
        restorePurchaseConfig.reset()
        
        HeliumIdentityManager.reset(clearUserTraits: clearUserTraits)
        
        HeliumEventListeners.shared.removeAllListeners()
        
        Helium.shared.reset()
        
        // NOTE - not clearing entitlements nor products cache nor transactions caches nor cached bundles
    }
    
}

/// Configuration object for user identification settings.
/// Set properties on `Helium.identify` before calling `Helium.shared.initialize()`.
///
/// Example:
/// ```swift
/// Helium.identify.userId = "user-123"
/// Helium.identify.setUserTraits(HeliumUserTraits(["plan": "premium"]))
/// Helium.shared.initialize(apiKey: "your-api-key")
/// ```
public class HeliumIdentify {
    
    /// Custom user ID to identify this user.
    public var userId: String {
        get {
            HeliumIdentityManager.shared.getUserId()
        }
        set {
            HeliumIdentityManager.shared.setCustomUserId(newValue)
            HeliumAnalyticsManager.shared.identify(userId: userId)
        }
    }
    
    /// Custom appAccountToken for StoreKit purchases. If not set, Helium will generate one.
    /// Only need to set if you use this value in App Store Server Notifications or your app makes non-Helium purchases with StoreKit.
    public var appAccountToken: UUID {
        get {
            HeliumIdentityManager.shared.appAttributionToken
        }
        set {
            HeliumIdentityManager.shared.setCustomAppAttributionToken(newValue)
        }
    }
    
    /// RevenueCat app user ID -- set this if you use RevenueCat along with Helium.
    public var revenueCatAppUserId: String? {
        get {
            HeliumIdentityManager.shared.revenueCatAppUserId
        }
        set {
            HeliumIdentityManager.shared.setRevenueCatAppUserId(newValue)
        }
    }
    
    /// Custom user traits for targeting and analytics.
    public func setUserTraits(_ traits: HeliumUserTraits) {
        HeliumIdentityManager.shared.setCustomUserTraits(traits)
    }
    public func addUserTraits(_ traits: HeliumUserTraits) {
        HeliumIdentityManager.shared.addToCustomUserTraits(traits)
    }
    public func getUserTraits() -> HeliumUserTraits? {
        HeliumIdentityManager.shared.getUserTraits()
    }
    
}

public class HeliumConfig {
    
    public static let defaultLoadingBudget: TimeInterval = 7.0
    
    public var purchaseDelegate: HeliumPaywallDelegate {
        get {
            HeliumPaywallDelegateWrapper.shared.getDelegate()
        }
        set {
            HeliumPaywallDelegateWrapper.shared.setDelegate(newValue)
        }
    }
    
    public var customFallbacksURL: URL? = nil
    
    public var customAPIEndpoint: String? = nil
    
    /// Maximum time (in seconds) to show the loading state before displaying fallback.
    /// After this timeout, even if the paywall is still downloading, a fallback will be shown if available.
    /// A value of 0 or less will disable the loading state.
    public var defaultLoadingBudget: TimeInterval = HeliumConfig.defaultLoadingBudget
    
    /// Custom loading view to display while fetching paywall configuration.
    /// If nil, a default shimmer animation will be shown.
    /// Default: nil (uses default shimmer)
    public var defaultLoadingView: AnyView? = nil
    
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
