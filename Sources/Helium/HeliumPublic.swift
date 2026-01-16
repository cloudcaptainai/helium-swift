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

public class Helium {
    var controller: HeliumController?
    private var initialized: Bool = false;
    var fallbackConfig: HeliumFallbackConfig?  // Set during initialize
    
    private(set) var lightDarkModeOverride: HeliumLightDarkMode = .system
    
    private func reset() {
        initialized = false
        controller = nil
        fallbackConfig = nil
        lightDarkModeOverride = .system
    }
    
    public static let shared = Helium()
    public static let restorePurchaseConfig = RestorePurchaseConfig()
    
    // MARK: - Logging

    /// Sets the Helium SDK log level.
    ///
    /// Defaults to `.error`. Increase to `.info` / `.debug` while integrating.
    public static func setLogLevel(_ level: HeliumLogLevel) {
        HeliumLog.setLogLevel(level)
    }

    /// Returns the current Helium SDK log level.
    public static func getLogLevel() -> HeliumLogLevel {
        HeliumLog.getLogLevel()
    }

    /// Instance convenience for setting the Helium SDK log level.
    public func setLogLevel(_ level: HeliumLogLevel) {
        HeliumLog.setLogLevel(level)
    }
    
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
                eventService: eventHandlers,
                customPaywallTraits: customPaywallTraits
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
        
        // Start store country code fetch immediately
        _ = AppStoreCountryHelper.shared
        
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
        
        // Use provided delegate or default to StoreKitDelegate
        let delegate = heliumPaywallDelegate ?? StoreKitDelegate()
        
        HeliumSdkConfig.shared.setInitializeConfig(
            purchaseDelegate: delegate.delegateType,
            customAPIEndpoint: customAPIEndpoint
        )
        
        self.controller = HeliumController(
            apiKey: apiKey
        )
        self.controller?.logInitializeEvent();
        
        HeliumPaywallDelegateWrapper.shared.setDelegate(delegate);
        controller?.setCustomAPIEndpoint(endpoint: customAPIEndpoint)
        self.controller!.downloadConfig();
        
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
