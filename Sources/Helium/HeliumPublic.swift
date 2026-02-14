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

/// Configuration options for presenting a paywall.
public struct PaywallPresentationConfig {
    var presentFromViewController: UIViewController? = nil
    var customPaywallTraits: [String: Any]? = nil
    var dontShowIfAlreadyEntitled: Bool = true
    var loadingBudget: TimeInterval? = nil

    /// Creates a new paywall presentation configuration.
    /// - Parameters:
    ///   - presentFromViewController: View controller to present from. Defaults to current top view controller. Ignored for `HeliumPaywall` embedded view.
    ///   - customPaywallTraits: Custom traits to send to the paywall.
    ///   - dontShowIfAlreadyEntitled: If `true`, skips showing the paywall when user is already entitled. Defaults to `true`.
    ///   - loadingBudget: Maximum time (in seconds) to show loading state before switching to fallback logic. Use zero or negative to disable loading state. Defaults to `Helium.config.defaultLoadingBudget`.
    public init(
        presentFromViewController: UIViewController? = nil,
        customPaywallTraits: [String: Any]? = nil,
        dontShowIfAlreadyEntitled: Bool = true,
        loadingBudget: TimeInterval? = nil
    ) {
        self.presentFromViewController = presentFromViewController
        self.customPaywallTraits = customPaywallTraits
        self.dontShowIfAlreadyEntitled = dontShowIfAlreadyEntitled
        self.loadingBudget = loadingBudget
    }
    
    var useLoadingState: Bool {
        effectiveLoadingBudget > 0
    }
    
    private var effectiveLoadingBudget: TimeInterval {
        return loadingBudget ?? Helium.config.defaultLoadingBudget
    }
    
    var safeLoadingBudgetInSeconds: TimeInterval {
        max(1, min(20, effectiveLoadingBudget))
    }
    
    var loadingBudgetForAnalyticsMS: UInt64 {
        if !useLoadingState {
            return 0
        }
        guard safeLoadingBudgetInSeconds > 0 else { return 0 }
        return UInt64(safeLoadingBudgetInSeconds * 1000)
    }
}

public class Helium {
    init() {}
    
    var controller: HeliumController?
    @HeliumAtomic private var initialized: Bool = false
    
    private func reset() {
        controller = nil
        initialized = false
    }
    
    public static let shared = Helium()
    public static let identify = HeliumIdentify()
    public static let config = HeliumConfig()
    public static let experiments = HeliumExperiments()
    public static let entitlements = HeliumEntitlements()
    @HeliumAtomic static var lastApiKeyUsed: String? = nil
    
    /// Presents a full-screen paywall for the specified trigger.
    ///
    /// You must have a trigger and workflow configured in the [Helium dashboard](https://app.tryhelium.com/workflows)
    /// in order to show a paywall.
    ///
    /// ## Example
    /// ```swift
    /// Helium.shared.presentPaywall(
    ///     trigger: "premium"
    /// ) { paywallNotShownReason in
    ///     switch paywallNotShownReason {
    ///         case .targetingHoldout:
    ///             break
    ///         case .alreadyEntitled:
    ///             // e.g. ensure premium access
    ///             break
    ///         default:
    ///             // handle the rare case where a paywall fails to show
    ///             break
    ///     }
    /// }
    /// ```
    ///
    /// - Note: See the [Fallbacks documentation](https://docs.tryhelium.com/guides/fallback-bundle) to reduce cases where a paywall fails to show.
    ///
    /// - Parameters:
    ///   - trigger: The trigger name configured in the Helium dashboard.
    ///   - config: Optional configuration for this paywall presentation. Defaults to `PaywallPresentationConfig()`.
    ///   - eventHandlers: Optional event handlers for paywall lifecycle events.
    ///   - onEntitled: Optional handler called when user becomes entitled to a product in the paywall, via purchase or existing entitlement.
    ///   - onPaywallNotShown: Required handler for any scenario where the paywall does not show.
    ///
    /// - Important: If user is already entitled and `config.dontShowIfAlreadyEntitled` is true,  `onEntitled` will be called if provided otherwise `onPaywallNotShown(.alreadyEntitled)` will be called.
    public func presentPaywall(
        trigger: String,
        config: PaywallPresentationConfig = PaywallPresentationConfig(),
        eventHandlers: PaywallEventHandlers? = nil,
        onEntitled: (() -> Void)? = nil,
        onPaywallNotShown: @escaping (PaywallNotShownReason) -> Void
    ) {
        HeliumLogger.log(.info, category: .ui, "presentUpsell called", metadata: ["trigger": trigger])
        
        let presentationContext = PaywallPresentationContext(
            config: config,
            eventHandlers: eventHandlers,
            onEntitled: onEntitled,
            onPaywallNotShown: onPaywallNotShown
        )
        if skipPaywallIfNeeded(trigger: trigger, presentationContext: presentationContext) {
            HeliumLogger.log(.debug, category: .ui, "Paywall skipped for trigger", metadata: ["trigger": trigger])
            return
        }
        
        HeliumPaywallPresenter.shared.presentUpsellWithLoadingBudget(trigger: trigger, presentationContext: presentationContext)
    }
    
    func skipPaywallIfNeeded(trigger: String, presentationContext: PaywallPresentationContext) -> Bool {
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        if paywallInfo?.shouldShow == false {
            handlePaywallSkip(trigger: trigger)
            presentationContext.onPaywallNotShown?(.targetingHoldout)
            return true
        }
        return false
    }
    
    func handlePaywallSkip(trigger: String) {
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
    }
    
    public func getDownloadStatus() -> HeliumFetchedConfigStatus {
        return HeliumFetchedConfigManager.shared.downloadStatus;
    }
    
    /// Hide the top-most paywall that was shown via presentPaywall, if any are currently displayed.
    @discardableResult
    public func hidePaywall() -> Bool {
        return HeliumPaywallPresenter.shared.hideUpsell();
    }
    
    /// Hide all currently displayed paywalls, including "second try" paywalls.
    public func hideAllPaywalls() {
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
        hideAllPaywalls()
        
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

        HeliumLogger.log(.info, category: .core, "All cached state cleared and SDK reset. Call initialize() before using Helium again.")
    }
    
    @available(*, deprecated, message: "Use HeliumPaywall directly instead")
    public func upsellViewForTrigger(trigger: String, eventHandlers: PaywallEventHandlers? = nil, customPaywallTraits: [String: Any]? = nil) -> AnyView? {
        let config = PaywallPresentationConfig(customPaywallTraits: customPaywallTraits)
        let presentationContext = PaywallPresentationContext(
            config: config,
            eventHandlers: eventHandlers,
            onEntitled: nil,
            onPaywallNotShown: nil
        )
        return upsellViewResultFor(trigger: trigger, presentationContext: presentationContext).viewAndSession?.view
    }
    
    func upsellViewResultFor(trigger: String, presentationContext: PaywallPresentationContext) -> PaywallViewResult {
        HeliumLogger.log(.debug, category: .ui, "upsellViewResultFor called", metadata: ["trigger": trigger])
        if !initialized {
            HeliumLogger.log(.warn, category: .core, "Helium not initialized when presenting paywall")
            return PaywallViewResult(viewAndSession: nil, fallbackReason: .notInitialized)
        }
        
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        if paywallsLoaded() && HeliumFetchedConfigManager.shared.hasBundles() {
            guard let templatePaywallInfo = paywallInfo else {
                return fallbackViewFor(trigger: trigger, paywallInfo: nil, fallbackReason: .triggerHasNoPaywall, presentationContext: presentationContext)
            }
            if templatePaywallInfo.forceShowFallback == true {
                return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: .forceShowFallback, presentationContext: presentationContext)
            }
            
            if let bundleSkip = HeliumFetchedConfigManager.shared.triggersWithSkippedBundleAndReason.first(where: { $0.trigger == trigger }) {
                return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: bundleSkip.reason, presentationContext: presentationContext)
            }
            
            if !templatePaywallInfo.hasIosProducts {
                return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: .noProductsIOS, presentationContext: presentationContext)
            }
            
            do {
                guard let filePath = templatePaywallInfo.localBundlePath else {
                    HeliumLogger.log(.warn, category: .ui, "No local bundle path for trigger", metadata: ["trigger": trigger])
                    return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: .couldNotFindBundleUrl, presentationContext: presentationContext)
                }
                let backupFilePath = HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger)?.localBundlePath
                
                let paywallSession = PaywallSession(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackType: .notFallback, presentationContext: presentationContext)
                
                let paywallView = try AnyView(DynamicBaseTemplateView(
                    paywallSession: paywallSession,
                    fallbackReason: nil,
                    filePath: filePath,
                    backupFilePath: backupFilePath,
                    resolvedConfig: HeliumFetchedConfigManager.shared.getResolvedConfigJSONForTrigger(trigger)
                ))
                HeliumLogger.log(.debug, category: .ui, "Created paywall view for trigger", metadata: ["trigger": trigger])
                return PaywallViewResult(viewAndSession: PaywallViewAndSession(view: paywallView, paywallSession: paywallSession), fallbackReason: nil)
            } catch {
                HeliumLogger.log(.error, category: .ui, "Failed to create Helium view wrapper: \(error). Falling back.", metadata: ["trigger": trigger])
                return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: .invalidResolvedConfig, presentationContext: presentationContext)
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
            return fallbackViewFor(trigger: trigger, paywallInfo: paywallInfo, fallbackReason: fallbackReason, presentationContext: presentationContext)
        }
    }
    
    private func fallbackViewFor(trigger: String, paywallInfo: HeliumPaywallInfo?, fallbackReason: PaywallUnavailableReason, presentationContext: PaywallPresentationContext) -> PaywallViewResult {
        
        // Check existing fallback mechanisms
        if let fallbackPaywallInfo = HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger),
           let filePath = fallbackPaywallInfo.localBundlePath {
            do {
                let fallbackBundlePaywallSession = PaywallSession(trigger: trigger, paywallInfo: fallbackPaywallInfo, fallbackType: .fallbackBundle, presentationContext: presentationContext)
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
                HeliumLogger.log(.warn, category: .fallback, "Failed to create fallback view", metadata: ["trigger": trigger, "error": "\(error)"])
            }
        }
        return PaywallViewResult(viewAndSession: nil, fallbackReason: fallbackReason)
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
        let upsellResult = upsellViewResultFor(trigger: trigger, presentationContext: PaywallPresentationContext.empty)
        let canShow = upsellResult.viewAndSession?.view != nil
        return CanShowPaywallResult(
            canShow: canShow,
            isFallback: canShow ? upsellResult.isFallback : nil,
            paywallUnavailableReason: upsellResult.fallbackReason
        )
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
    public func initialize(
        apiKey: String
    ) {
        HeliumLogger.log(.info, category: .core, "Helium.initialize() called")
        let alreadyInitialized = _initialized.withValue { value in
            if value { return true }
            value = true
            return false
        }
        if alreadyInitialized {
            HeliumLogger.log(.debug, category: .core, "Helium already initialized, skipping")
            return
        }
        
        // Start store country code fetch immediately
        _ = AppStoreCountryHelper.shared
        
        AppReceiptsHelper.shared.setUp()
        
        HeliumFallbackViewManager.shared.setUpFallbackBundle()
        
        HeliumSdkConfig.shared.setInitializeConfig(
            purchaseDelegate: Helium.config.purchaseDelegate.delegateType,
            customAPIEndpoint: Helium.config.customAPIEndpoint
        )
        
        Helium.lastApiKeyUsed = apiKey
        let fetchController = HeliumController(
            apiKey: apiKey
        )
        self.controller = fetchController
        fetchController.logInitializeEvent()
        fetchController.downloadConfig()
        
        Task {
            await WebViewManager.shared.preCreateFirstWebView()

            await HeliumEntitlementsManager.shared.configure()
            await HeliumTransactionManager.shared.configure()
        }
    }

    func isInitialized() -> Bool {
        return initialized
    }

    /// Marks the SDK as initialized without triggering side effects (config fetch, analytics, etc.).
    /// Accessible via @testable import for unit tests.
    func markInitializedForTesting() {
        initialized = true
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
            HeliumLogger.log(.warn, category: .core, "handleDeepLink - Invalid test URL format", metadata: ["url": url.absoluteString])
            return false
        }

        var triggerValue = queryItems.first(where: { $0.name == "trigger" })?.value
        let paywallUUID = queryItems.first(where: { $0.name == "puid" })?.value

        if triggerValue == nil && paywallUUID == nil {
            HeliumLogger.log(.warn, category: .core, "handleDeepLink - Test URL needs 'trigger' or 'puid'", metadata: ["url": url.absoluteString])
            return false
        }

        // Do not show fallbacks... check to see if the needed bundle is available
        if !paywallsLoaded() {
            HeliumLogger.log(.warn, category: .core, "handleDeepLink - Helium has not completed initialization")
            return false
        }

        if let paywallUUID, triggerValue == nil {
            triggerValue = HeliumFetchedConfigManager.shared.getTriggerFromPaywallUuid(paywallUUID)
            if triggerValue == nil {
                HeliumLogger.log(.warn, category: .core, "handleDeepLink - Could not find trigger for paywall UUID", metadata: ["uuid": paywallUUID])
            }
        }

        guard let trigger = triggerValue else {
            return false
        }

        if getPaywallInfo(trigger: trigger) == nil {
            HeliumLogger.log(.warn, category: .core, "handleDeepLink - Bundle not available for trigger", metadata: ["trigger": trigger])
            return false
        }
        
        // hide any existing upsells
        hideAllPaywalls()
        
        HeliumLogger.log(.info, category: .core, "handleDeepLink - Presenting paywall for trigger", metadata: ["trigger": trigger])
        presentPaywall(trigger: trigger, config: PaywallPresentationConfig(dontShowIfAlreadyEntitled: false)) { reason in
            HeliumLogger.log(.info, category: .core, "handleDeepLink - Could not show paywall", metadata: ["reason": reason.description])
        }
        return true
    }
    
    /// Reset Helium entirely so you can call initialize again. Only for advanced use cases.
    ///
    /// - Parameters:
    ///   - clearUserTraits: Whether to clear user traits set via `Helium.identify`. Defaults to `true`.
    ///   - clearHeliumEventListeners: Whether to remove all event listeners. Defaults to `true`.
    ///   - clearExperimentAllocations: Whether to clear experiment allocations. Defaults to `false`.
    ///   - autoInitialize: If `true`, automatically re-initializes Helium with the last used API key after the reset completes.
    ///   - onComplete: Called when the reset has completed. If `autoInitialize` is true, `onComplete` will be called once Helium.shared.initialize has kicked
    ///   off.
    public static func resetHelium(
        clearUserTraits: Bool = true,
        clearHeliumEventListeners: Bool = true,
        clearExperimentAllocations: Bool = false,
        autoInitialize: Bool = false,
        onComplete: (() -> Void)? = nil
    ) {
        HeliumPaywallPresenter.shared.hideAllUpsells {
            // Clear fetched configuration from memory
            HeliumFetchedConfigManager.reset()
            
            // Completely reset all fallback configurations
            HeliumFallbackViewManager.reset()
            
            if clearExperimentAllocations {
                ExperimentAllocationTracker.shared.reset()
            }
            
            HeliumIdentityManager.reset(clearUserTraits: clearUserTraits)
            
            if clearHeliumEventListeners {
                HeliumEventListeners.shared.removeAllListeners()
            }
            
            Helium.shared.reset()
            
            // NOTE - not clearing entitlements nor products cache nor transactions caches nor cached bundles
            
            if autoInitialize, let apiKey = Helium.lastApiKeyUsed {
                Helium.shared.initialize(apiKey: apiKey)
            }
            
            onComplete?()
        }
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
    
    init() {}
    
    /// Custom user ID to identify this user.
    public var userId: String? {
        get {
            HeliumIdentityManager.shared.getCustomUserId()
        }
        set {
            HeliumIdentityManager.shared.setCustomUserId(newValue)
            HeliumAnalyticsManager.shared.identify()
        }
    }
    
    /// Custom appAccountToken for StoreKit purchases. If not set, Helium will generate one.
    /// Only need to set if you use this value in App Store Server Notifications or your app makes non-Helium purchases with StoreKit.
    public var appAccountToken: UUID {
        get {
            HeliumIdentityManager.shared.appAttributionToken
        }
        set {
            HeliumIdentityManager.shared.setCustomAppAccountToken(newValue)
        }
    }
    
    /// RevenueCat app user ID -- set this if you use RevenueCat along with Helium.
    public var revenueCatAppUserId: String? {
        get {
            HeliumIdentityManager.shared.revenueCatAppUserId
        }
        set {
            if let newValue {
                HeliumIdentityManager.shared.setRevenueCatAppUserId(newValue)
            }
        }
    }
    
    /// Custom user traits for targeting and analytics.
    public func setUserTraits(_ traits: HeliumUserTraits) {
        HeliumIdentityManager.shared.setCustomUserTraits(traits)
    }
    public func addUserTraits(_ traits: HeliumUserTraits) {
        HeliumIdentityManager.shared.addToCustomUserTraits(traits)
    }
    public func getUserTraits() -> [String : Any] {
        HeliumIdentityManager.shared.getUserTraits().dictionaryRepresentation
    }
    
}

public class HeliumConfig {
    
    init() {}
    
    /// Sets the Helium SDK log level.
    ///
    /// Defaults to `.info` if DEBUG otherwise `.error`
    ///
    public var logLevel: HeliumLogLevel {
        get {
            HeliumLogger.getLogLevel()
        }
        set {
            HeliumLogger.setLogLevel(newValue)
        }
    }
    
    /// Adjust to RevenueCatDelegate() if using RevenueCat or if you want to handle your own purchase logic, create a custom implementation. You can also subclass
    /// StoreKitDelegate or RevenueCatDelegate for custom implementations.
    public var purchaseDelegate: HeliumPaywallDelegate = StoreKitDelegate()
    
    /// By default, Helium will look for a file named "helium-fallbacks.json". Override by setting this.
    /// See https://docs.tryhelium.com/guides/fallback-bundle
    public var customFallbacksURL: URL? = nil
    
    /// Set a custom Helium API endpoint to use. Only set this if told to do so by Helium.
    public var customAPIEndpoint: String? = nil
    
    /// Maximum time (in seconds) to show the loading state before displaying fallback.
    /// After this timeout, even if the paywall is still downloading, a fallback will be shown if available.
    /// A value of 0 or less will disable the loading state.
    public var defaultLoadingBudget: TimeInterval = 7.0
    
    /// Custom loading view to display while fetching paywall configuration.
    /// If nil, a default shimmer animation will be shown.
    /// Default: nil (uses default shimmer)
    public var defaultLoadingView: AnyView? = nil
    
    /// Sets the light/dark mode override for Helium paywalls.
    /// - Parameter mode: The desired appearance mode (.light, .dark, or .system)
    /// - Note: .system respects the device's current appearance setting (default)
    public var lightDarkModeOverride: HeliumLightDarkMode = .system
    
    /// Adjust the text copy for the dialog that shows when a user attempts to restore purchases but does not have any to restore. You can also disable the dialog from showing.
    public let restorePurchasesDialog = RestorePurchaseConfig()
    
}

public class HeliumExperiments {
    init() {}
    
    /// Get experiment allocation info for a specific trigger
    ///
    /// - Parameter trigger: The trigger name to get experiment info for
    /// - Returns: ExperimentInfo if the trigger has experiment data, nil otherwise
    ///
    /// ## Example Usage
    /// ```swift
    /// if let experimentInfo = Helium.experiments.infoForTrigger("onboarding") {
    ///     print("Experiment: \(experimentInfo.experimentName ?? "unknown")")
    ///     print("Variant: \(experimentInfo.chosenVariantDetails?.allocationIndex ?? 0)")
    /// }
    /// ```
    ///
    /// - SeeAlso: `ExperimentInfo`, `getHeliumExperimentInfo()`
    public func infoForTrigger(_ trigger: String) -> ExperimentInfo? {
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
    /// if let activeExperiments = Helium.experiments.enrolled() {
    ///     for experiment in activeExperiments {
    ///         print("Active: \(experiment.trigger) - \(experiment.experimentName ?? "unknown")")
    ///         print("Enrolled at: \(experiment.enrolledAt?.description ?? "unknown")")
    ///         print("Variant: \(experiment.chosenVariantDetails?.allocationName ?? "unknown")")
    ///     }
    /// }
    /// ```
    /// - SeeAlso: `allExperiments()`, `ExperimentInfo`, `ExperimentEnrollmentStatus`
    public func enrolled() -> [ExperimentInfo]? {
        guard HeliumFetchedConfigManager.shared.getConfig() != nil else {
            return nil
        }
        
        let triggers = HeliumFetchedConfigManager.shared.getFetchedTriggerNames()
        var activeExperiments: [ExperimentInfo] = []
        
        for trigger in triggers {
            if let experimentInfo = infoForTrigger(trigger),
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
    /// if let allExperiments = Helium.experiments.all() {
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
    public func all() -> [ExperimentInfo]? {
        guard HeliumFetchedConfigManager.shared.getConfig() != nil else {
            return nil
        }
        
        let triggers = HeliumFetchedConfigManager.shared.getFetchedTriggerNames()
        var allExperiments: [ExperimentInfo] = []
        
        for trigger in triggers {
            if let experimentInfo = infoForTrigger(trigger),
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
}

public class HeliumEntitlements {
    init() {}
    
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
    public func hasAny() async -> Bool {
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
