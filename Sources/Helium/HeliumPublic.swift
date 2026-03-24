import Foundation
import SwiftUI
import StoreKit

/// The main entry point for the Helium SDK.
///
/// - Latest docs: https://docs.tryhelium.com/sdk/quickstart-ios
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
    
    /// Initializes the Helium paywall system.
    /// - Set up user identification using Helium.identify, ideally before calling initialize().
    /// - Adjust Helium configuration using Helium.config, ideally before calling initialize().
    /// - Initialize as early as possible in your app’s lifecycle
    /// - Latest docs at https://docs.tryhelium.com/sdk/quickstart-ios
    ///
    /// - Parameters:
    ///   - apiKey: Your Helium API key from the dashboard https://app.tryhelium.com/profile
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
            HeliumLogger.log(.warn, category: .core, "Helium already initialized, ignoring subsequent call. Use resetHelium if you need to initialize again.")
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
    
    /// Presents a full-screen paywall for the specified trigger.
    ///
    /// You must have a trigger and workflow configured in the [Helium dashboard](https://app.tryhelium.com/workflows)
    /// in order to show a paywall.
    ///
    /// - Parameters:
    ///   - trigger: The trigger configured in the Helium dashboard.
    ///   - config: Optional configuration for this paywall presentation. Defaults to `PaywallPresentationConfig()`.
    ///   - eventHandlers: Optional event handlers for paywall lifecycle events.
    ///   - onEntitled: (Optional) Called upon purchase success or purchase restore. If you set `dontShowIfAlreadyEntitled`
    ///    to true, this handler will also be called when paywall not shown to users who already have entitlement for a product in the paywall.
    ///   - onPaywallNotShown: Called if desired paywall and fallback paywall did not show for any reason.
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
        if HeliumPaywallPresenter.shared.skipPaywallIfNeeded(trigger: trigger, presentationContext: presentationContext) {
            HeliumLogger.log(.debug, category: .ui, "Paywall skipped for trigger", metadata: ["trigger": trigger])
            return
        }
        
        HeliumPaywallPresenter.shared.presentUpsellWithLoadingBudget(trigger: trigger, presentationContext: presentationContext)
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
    
    /// Checks whether a paywall can be displayed for the given trigger without actually presenting it.
    ///
    /// In most cases you don't need this — ``presentPaywall()`` already handles availability checks and fallback logic for you.
    ///
    /// - Parameter trigger: The trigger configured in the Helium dashboard.
    /// - Returns: A ``CanShowPaywallResult`` indicating whether a paywall can show, whether it would be a fallback, and the reason if it is not ready to be shown.
    ///
    /// - Note: This does not account for entitlement status or targeting holdouts. A result of `canShow == true` means the paywall content is available, not that it will necessarily be presented to the user.
    public func canShowPaywallFor(trigger: String) -> CanShowPaywallResult {
        let upsellResult = HeliumPaywallPresenter.shared.upsellViewResultFor(
            trigger: trigger, presentationContext: PaywallPresentationContext.empty)
        
        let canShow = upsellResult.viewAndSession?.view != nil
        return CanShowPaywallResult(
            canShow: canShow,
            isFallback: canShow ? upsellResult.isFallback : nil,
            paywallUnavailableReason: upsellResult.fallbackReason
        )
    }
    
    /// Returns metadata about the paywall configured for a given trigger.
    ///
    /// Requires that paywalls have finished downloading (see ``paywallsLoaded()``).
    ///
    /// - Parameter trigger: The trigger configured in the Helium dashboard.
    /// - Returns: A ``PaywallInfo`` containing the paywall template name and whether it should show, or `nil` if paywalls haven't loaded or no paywall is configured for this trigger.
    public func getPaywallInfo(trigger: String) -> PaywallInfo? {
        if !paywallsLoaded() {
            return nil
        }
        guard let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger) else {
            return nil
        }
        return PaywallInfo(paywallTemplateName: paywallInfo.paywallTemplateName, shouldShow: paywallInfo.shouldShow ?? true)
    }
    
    /// Returns `true` if the Helium configuration has been successfully downloaded and paywalls are ready to present.
    public func paywallsLoaded() -> Bool {
        if case .downloadSuccess = HeliumFetchedConfigManager.shared.downloadStatus {
            return true;
        }
        return false;
    }
    
    /// Returns the current download status of the Helium paywall configuration.
    ///
    /// - SeeAlso: ``paywallsLoaded()``
    public func getDownloadStatus() -> HeliumFetchedConfigStatus {
        return HeliumFetchedConfigManager.shared.downloadStatus
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
    /// - Returns: Whether the deep link was handled.
    @available(*, deprecated, message: "Deep link handling is being replaced with paywall previews.")
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
    ///   - clearUserId: Whether to clear custom user ID. Defaults to `false`.
    ///   - clearUserTraits: Whether to clear user traits set via `Helium.identify`. Defaults to `true`.
    ///   - clearHeliumEventListeners: Whether to remove all event listeners. Defaults to `false`.
    ///   - clearExperimentAllocations: Whether to clear experiment allocations. Defaults to `false`.
    ///   - clearCachedPaywalls: Whether to clear cached paywall bundle files from disk. Defaults to `false`.
    ///   - autoInitialize: If `true`, automatically re-initializes Helium with the last used API key after the reset completes.
    ///   - onComplete: Called when the reset has completed. If `autoInitialize` is true, `onComplete` will be called once Helium.shared.initialize has kicked
    ///   off.
    public static func resetHelium(
        clearUserId: Bool = false,
        clearUserTraits: Bool = true,
        clearHeliumEventListeners: Bool = false,
        clearExperimentAllocations: Bool = false,
        clearCachedPaywalls: Bool = false,
        autoInitialize: Bool = false,
        onComplete: (() -> Void)? = nil
    ) {
        HeliumPaywallPresenter.shared.hideAllUpsells {
            if clearCachedPaywalls {
                HeliumAssetManager.shared.clearCache()
            }
            
            // Clear fetched configuration from memory
            HeliumFetchedConfigManager.reset()
            
            // Completely reset all fallback configurations
            HeliumFallbackViewManager.reset()
            
            if clearExperimentAllocations {
                ExperimentAllocationTracker.shared.reset()
            }
            
            HeliumIdentityManager.reset(clearUserId: clearUserId, clearUserTraits: clearUserTraits)
            
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
    
    func isInitialized() -> Bool {
        return initialized
    }

    /// Marks the SDK as initialized without triggering side effects (config fetch, analytics, etc.).
    /// Accessible via @testable import for unit tests.
    func markInitializedForTesting() {
        initialized = true
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
        return HeliumPaywallPresenter.shared.upsellViewResultFor(
            trigger: trigger, presentationContext: presentationContext
        ).viewAndSession?.view
    }
    
}

/// Configuration options for presenting a paywall.
public struct PaywallPresentationConfig {
    var presentFromViewController: UIViewController?
    var customPaywallTraits: [String: Any]?
    var dontShowIfAlreadyEntitled: Bool
    var loadingBudget: TimeInterval?

    /// Creates a new paywall presentation configuration.
    /// - Parameters:
    ///   - presentFromViewController: View controller to present from. Defaults to current top view controller. Ignored for `HeliumPaywall` embedded view.
    ///   - customPaywallTraits: Custom traits to send to the paywall.
    ///   - dontShowIfAlreadyEntitled: If `true`, skips showing the paywall when user is already entitled. Defaults to `false`.
    ///   - loadingBudget: Maximum time (in seconds) to show loading state before switching to fallback logic. Use zero or negative to disable loading state. Defaults to `Helium.config.defaultLoadingBudget`.
    public init(
        presentFromViewController: UIViewController? = nil,
        customPaywallTraits: [String: Any]? = nil,
        dontShowIfAlreadyEntitled: Bool = false,
        loadingBudget: TimeInterval? = nil
    ) {
        self.presentFromViewController = presentFromViewController
        self.customPaywallTraits = customPaywallTraits
        self.dontShowIfAlreadyEntitled = dontShowIfAlreadyEntitled
        self.loadingBudget = loadingBudget
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
    
    /// Your application's user ID for this user. Used for targeting and analytics.
    ///
    /// Set this before calling `Helium.shared.initialize()` for best results. Can also be updated after initialization.
    public var userId: String? {
        get {
            HeliumIdentityManager.shared.getCustomUserId()
        }
        set {
            let userIdChanged = newValue != HeliumIdentityManager.shared.getCustomUserId()
            if !userIdChanged && HeliumIdentityManager.shared.hasCustomUserId() {
                return
            }
            HeliumIdentityManager.shared.setCustomUserId(newValue)
            if newValue != nil && userIdChanged {
                HeliumAnalyticsManager.shared.identify()
            }
        }
    }
    
    /// Custom `appAccountToken` for StoreKit purchases. If not set, Helium will generate one automatically.
    ///
    /// Only set this if you use this value in App Store Server Notifications or your app makes non-Helium purchases with StoreKit.
    public var appAccountToken: UUID {
        get {
            HeliumIdentityManager.shared.appAttributionToken
        }
        set {
            HeliumIdentityManager.shared.setCustomAppAccountToken(newValue)
        }
    }
    
    /// RevenueCat app user ID. Set this if you use RevenueCat alongside Helium to keep user identity in sync.
    ///
    /// Update this whenever the RevenueCat user ID changes (e.g., after login/logout).
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
    
    /// An optional anonymous ID from your third-party analytics provider, sent alongside every Helium analytics event
    /// so you can correlate Helium data with your own analytics before `userId` is set.
    ///
    /// - Amplitude: pass device ID
    /// - Mixpanel: pass anonymous ID
    /// - PostHog: pass anonymous ID
    ///
    /// Set this before calling `Helium.shared.initialize()` for best results. Can also be updated after initialization.
    public var thirdPartyAnalyticsAnonymousId: String? {
        get {
            HeliumIdentityManager.shared.getThirdPartyAnalyticsAnonymousId()
        }
        set {
            HeliumIdentityManager.shared.setThirdPartyAnalyticsAnonymousId(newValue)
        }
    }

    /// Replaces all custom user traits with the provided traits. Used for audience targeting and analytics.
    ///
    /// Traits are persisted across app sessions. They are applied immediately for analytics, but paywall
    /// targeting is evaluated at initialization time. To use updated traits for targeting, reset Helium and initialize again.
    ///
    /// - Parameter traits: The new set of user traits.
    /// - SeeAlso: ``addUserTraits(_:)``
    public func setUserTraits(_ traits: HeliumUserTraits) {
        HeliumIdentityManager.shared.setCustomUserTraits(traits)
    }
    /// Replaces all custom user traits with the provided dictionary.
    ///
    /// - Parameter traits: A dictionary of traits. Supports JSON-compatible types: String, Int, Double, Bool, Array, Dictionary.
    public func setUserTraits(_ traits: [String: Any]) {
        HeliumIdentityManager.shared.setCustomUserTraits(HeliumUserTraits(traits))
    }
    /// Merges the provided traits into the existing custom user traits, overwriting any matching keys.
    ///
    /// Traits are persisted across app sessions. They are applied immediately for analytics, but paywall
    /// targeting is evaluated at initialization time. To use updated traits for targeting, reset Helium and initialize again.
    ///
    /// - Parameter traits: The traits to add or update.
    /// - SeeAlso: ``setUserTraits(_:)``
    public func addUserTraits(_ traits: HeliumUserTraits) {
        HeliumIdentityManager.shared.addToCustomUserTraits(traits)
    }
    /// Merges the provided dictionary into the existing custom user traits, overwriting any matching keys.
    ///
    /// - Parameter traits: A dictionary of traits. Supports JSON-compatible types: String, Int, Double, Bool, Array, Dictionary.
    public func addUserTraits(_ traits: [String: Any]) {
        HeliumIdentityManager.shared.addToCustomUserTraits(HeliumUserTraits(traits))
    }
    /// Returns the current custom user traits as a dictionary.
    ///
    /// - Note: Numeric values that were set as `Int` may be returned as `Double` after an app restart
    ///   due to JSON serialization. Use `as? Double` when reading numeric traits.
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
    
    /// Registers a third-party entitlements source.
    /// The entitlements manager will query this source alongside StoreKit using OR-logic.
    /// Set this before calling `Helium.shared.initialize()`.
    public var thirdPartyEntitlementsSource: ThirdPartyEntitlementsSource? = nil
    
    /// Adjust the text copy for the dialog that shows when a user attempts to restore purchases but does not have any to restore. You can also disable the dialog from showing.
    public let restorePurchasesDialog = RestorePurchaseConfig()
    
    /// Controls whether a debug diagnostic view is shown when a paywall fails to display or is skipped.
    /// Only applies in DEBUG builds. Defaults to `true`.
    /// The debug view also contains a "Do not show again" checkbox that persists per-device via UserDefaults (resets on app delete).
    /// Set this to `false` to disable the diagnostic view for all users in DEBUG builds.
    public var paywallNotShownDiagnosticDisplayEnabled: Bool = true
    
}

public class HeliumExperiments {
    init() {}
    
    /// Get experiment allocation info for a specific trigger
    ///
    /// - Parameter trigger: The trigger to get experiment info for
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
    /// This method provides a wrapper around the standard purchase flow.
    /// Typically only used for advanced custom purchase delegate implementations.
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
