import Foundation
import SwiftUI

/// Per-trigger loading configuration for customizing loading behavior on a per-trigger basis.
///
/// Use this to override global loading settings for specific paywall triggers.
/// For example, you might want to disable loading state for your onboarding flow
/// but keep it enabled for other paywalls.
///
/// ## Example
/// ```swift
/// let config = TriggerLoadingConfig(
///     useLoadingState: false,  // Disable loading for this trigger
///     loadingBudget: 1.0,      // Float value of the loading budget
///     loadingView: AnyView(CustomLoadingView())  // Or custom view
/// )
/// ```
public struct TriggerLoadingConfig {
    /// Whether to show loading state for this trigger.
    /// Set to nil to use the global `useLoadingState` setting.
    public var useLoadingState: Bool?
    
    /// Maximum seconds to show loading for this trigger.
    /// Set to nil to use the global `loadingBudget` setting.
    public var loadingBudget: TimeInterval?
    
    /// Custom loading view for this trigger.
    /// Set to nil to use the global `loadingView` or default shimmer.
    public var loadingView: AnyView?
    
    /// Creates a trigger-specific loading configuration.
    ///
    /// All parameters are optional. Nil values fall back to global settings.
    ///
    /// - Parameters:
    ///   - useLoadingState: Override whether to show loading (nil = use global)
    ///   - loadingBudget: Override loading timeout in seconds (nil = use global)
    ///   - loadingView: Custom loading view for this trigger (nil = use global)
    public init(
        useLoadingState: Bool? = nil,
        loadingBudget: TimeInterval? = nil,
        loadingView: AnyView? = nil
    ) {
        self.useLoadingState = useLoadingState
        self.loadingBudget = loadingBudget
        self.loadingView = loadingView
    }
}

/// Configuration for fallback and loading behavior when paywalls are not immediately available.
///
/// This struct provides comprehensive control over what users see when:
/// - Paywalls are still downloading from the network
/// - Network requests fail
/// - Paywall configuration is missing for a trigger
///
/// ## Loading States
/// When `useLoadingState` is true, Helium will show a loading view for up to `loadingBudget` seconds
/// while fetching paywall configuration. This provides a better user experience than immediately
/// showing a fallback.
///
/// ## Fallback Priority
/// When a paywall cannot be fetched from the network, fallbacks are resolved in this order:
/// 1. **Fallback bundle** - If a trigger exists in the bundle JSON, uses that configuration
/// 2. **Per-trigger fallback views** - Trigger-specific SwiftUI views (from `fallbackPerTrigger`)
/// 3. **Global fallback view** - Single SwiftUI view for all triggers (from `fallbackView`)
///
/// Note: At least one fallback mechanism is required during initialization.
///
/// ## Example Usage
/// ```swift
/// // Simple fallback view
/// let config = HeliumFallbackConfig.withFallbackView(
///     MyFallbackView(),
///     loadingBudget: 3.0
/// )
///
/// // Fallback bundle with custom loading settings
/// let config = HeliumFallbackConfig.withFallbackBundleAndTriggerSettings(
///     bundleURL: bundleURL,
///     globalLoadingBudget: 2.0,
///     triggerSettings: [
///         "onboarding": (useLoading: false, budget: nil, view: nil),
///         "premium_upgrade": (useLoading: true, budget: 5.0, view: CustomLoadingView())
///     ]
/// )
/// ```
public struct HeliumFallbackConfig {
    // Loading settings
    /// Whether to show a loading state while fetching paywall configuration.
    /// When true, shows a loading view for up to `loadingBudget` seconds before falling back.
    /// Default: true
    public var useLoadingState: Bool = true
    
    /// Maximum time (in seconds) to show the loading state before displaying fallback.
    /// After this timeout, the fallback view will be shown even if the paywall is still downloading.
    /// Default: 2.0 seconds
    public var loadingBudget: TimeInterval = 2.0
    
    /// Custom loading view to display while fetching paywall configuration.
    /// If nil, a default shimmer animation will be shown.
    /// Default: nil (uses default shimmer)
    public var loadingView: AnyView? = nil
    
    // Per-trigger loading overrides
    /// Optional per-trigger loading configuration overrides.
    /// Use this to customize loading behavior for specific triggers.
    /// Keys are trigger names, values are TriggerLoadingConfig instances.
    /// Example: Disable loading for "onboarding" trigger while keeping it for others.
    public var perTriggerLoadingConfig: [String: TriggerLoadingConfig]? = nil
    
    /// Per-trigger fallback views for specific triggers.
    /// Keys are trigger names, values are SwiftUI views to display as fallback.
    public var fallbackPerTrigger: [String: AnyView]? = nil
    
    /// URL to a fallback bundle JSON file.
    /// This bundle can be downloaded from the Helium dashboard and bundled with your app.
    /// Provides rich, configurable fallback paywalls without hardcoding views.
    public var fallbackBundle: URL? = nil
    
    /// Global fallback view used when no trigger-specific fallback is available.
    /// This is the last resort before showing an empty view.
    public var fallbackView: AnyView? = nil
    
    // Private initializer to prevent creating without fallback
    private init(
        useLoadingState: Bool,
        loadingBudget: TimeInterval,
        loadingView: AnyView?,
        perTriggerLoadingConfig: [String: TriggerLoadingConfig]?,
        fallbackView: AnyView?,
        fallbackPerTrigger: [String: AnyView]?,
        fallbackBundle: URL?
    ) {
        self.useLoadingState = useLoadingState
        self.loadingBudget = loadingBudget
        self.loadingView = loadingView
        self.perTriggerLoadingConfig = perTriggerLoadingConfig
        self.fallbackView = fallbackView
        self.fallbackPerTrigger = fallbackPerTrigger
        self.fallbackBundle = fallbackBundle
    }
    
    /// Creates a configuration with a single global fallback view.
    ///
    /// Use this for simple fallback scenarios where all triggers should show the same fallback.
    ///
    /// - Parameters:
    ///   - view: The SwiftUI view to display as fallback for all triggers
    ///   - useLoadingState: Whether to show loading state before fallback (default: true)
    ///   - loadingBudget: Maximum seconds to show loading state (default: 2.0)
    ///   - loadingView: Custom loading view, or nil for default shimmer
    ///   - perTriggerLoadingConfig: Optional per-trigger loading overrides
    /// - Returns: A configured HeliumFallbackConfig instance
    public static func withFallbackView(
        _ view: any View,
        useLoadingState: Bool = true,
        loadingBudget: TimeInterval = 2.0,
        loadingView: AnyView? = nil,
        perTriggerLoadingConfig: [String: TriggerLoadingConfig]? = nil
    ) -> HeliumFallbackConfig {
        return HeliumFallbackConfig(
            useLoadingState: useLoadingState,
            loadingBudget: loadingBudget,
            loadingView: loadingView,
            perTriggerLoadingConfig: perTriggerLoadingConfig,
            fallbackView: AnyView(view),
            fallbackPerTrigger: nil,
            fallbackBundle: nil
        )
    }
    
    /// Creates a configuration with different fallback views for each trigger.
    ///
    /// Use this when different triggers require different fallback experiences.
    /// For example, a simpler fallback for onboarding vs. a full-featured one for premium upgrade.
    ///
    /// - Parameters:
    ///   - fallbacks: Dictionary mapping trigger names to their fallback views
    ///   - useLoadingState: Whether to show loading state before fallback (default: true)
    ///   - loadingBudget: Maximum seconds to show loading state (default: 2.0)
    ///   - loadingView: Custom loading view, or nil for default shimmer
    ///   - perTriggerLoadingConfig: Optional per-trigger loading overrides
    /// - Returns: A configured HeliumFallbackConfig instance
    public static func withPerTriggerFallbacks(
        _ fallbacks: [String: any View],
        useLoadingState: Bool = true,
        loadingBudget: TimeInterval = 2.0,
        loadingView: AnyView? = nil,
        perTriggerLoadingConfig: [String: TriggerLoadingConfig]? = nil
    ) -> HeliumFallbackConfig {
        var anyViewMap: [String: AnyView] = [:]
        for (key, view) in fallbacks {
            anyViewMap[key] = AnyView(view)
        }
        return HeliumFallbackConfig(
            useLoadingState: useLoadingState,
            loadingBudget: loadingBudget,
            loadingView: loadingView,
            perTriggerLoadingConfig: perTriggerLoadingConfig,
            fallbackView: nil,
            fallbackPerTrigger: anyViewMap,
            fallbackBundle: nil
        )
    }
    
    /// Creates a configuration with a fallback bundle from the Helium dashboard.
    ///
    /// Fallback bundles provide rich, configurable paywalls without hardcoding views in your app.
    /// Download the bundle from the Helium dashboard and include it in your app bundle.
    ///
    /// - Parameters:
    ///   - url: URL to the fallback bundle JSON file (typically in your app bundle)
    ///   - useLoadingState: Whether to show loading state before fallback (default: true)
    ///   - loadingBudget: Maximum seconds to show loading state (default: 2.0)
    ///   - loadingView: Custom loading view, or nil for default shimmer
    ///   - perTriggerLoadingConfig: Optional per-trigger loading overrides
    /// - Returns: A configured HeliumFallbackConfig instance
    ///
    /// - Example:
    /// ```swift
    /// let bundleURL = Bundle.main.url(forResource: "fallback-bundle", withExtension: "json")!
    /// let config = HeliumFallbackConfig.withFallbackBundle(
    ///     bundleURL,
    ///     loadingBudget: 3.0
    /// )
    /// ```
    public static func withFallbackBundle(
        _ url: URL,
        useLoadingState: Bool = true,
        loadingBudget: TimeInterval = 2.0,
        loadingView: AnyView? = nil,
        perTriggerLoadingConfig: [String: TriggerLoadingConfig]? = nil
    ) -> HeliumFallbackConfig {
        return HeliumFallbackConfig(
            useLoadingState: useLoadingState,
            loadingBudget: loadingBudget,
            loadingView: loadingView,
            perTriggerLoadingConfig: perTriggerLoadingConfig,
            fallbackView: nil,
            fallbackPerTrigger: nil,
            fallbackBundle: url
        )
    }
    
    /// Creates a configuration with multiple fallback mechanisms.
    ///
    /// This method allows combining different fallback strategies:
    /// - Fallback bundle for rich, configurable fallbacks
    /// - Per-trigger views for trigger-specific experiences
    /// - Global fallback view as a last resort
    ///
    /// At least one fallback mechanism must be provided.
    ///
    /// - Parameters:
    ///   - fallbackView: Optional global fallback view
    ///   - fallbackPerTrigger: Optional per-trigger fallback views
    ///   - fallbackBundle: Optional fallback bundle URL
    ///   - useLoadingState: Whether to show loading state (default: true)
    ///   - loadingBudget: Maximum seconds to show loading (default: 2.0)
    ///   - loadingView: Custom loading view or nil for default
    ///   - perTriggerLoadingConfig: Optional per-trigger loading overrides
    /// - Returns: Optional HeliumFallbackConfig, nil if no fallback mechanism provided
    public static func withMultipleFallbacks(
        fallbackView: (any View)? = nil,
        fallbackPerTrigger: [String: any View]? = nil,
        fallbackBundle: URL? = nil,
        useLoadingState: Bool = true,
        loadingBudget: TimeInterval = 2.0,
        loadingView: AnyView? = nil,
        perTriggerLoadingConfig: [String: TriggerLoadingConfig]? = nil
    ) -> HeliumFallbackConfig? {
        // Require at least one fallback mechanism
        guard fallbackView != nil || fallbackPerTrigger != nil || fallbackBundle != nil else {
            print("[Helium] Fallback not configured correctly")
            return nil
        }
        
        var anyViewPerTrigger: [String: AnyView]? = nil
        if let triggers = fallbackPerTrigger {
            anyViewPerTrigger = [:]
            for (key, view) in triggers {
                anyViewPerTrigger![key] = AnyView(view)
            }
        }
        
        return HeliumFallbackConfig(
            useLoadingState: useLoadingState,
            loadingBudget: loadingBudget,
            loadingView: loadingView,
            perTriggerLoadingConfig: perTriggerLoadingConfig,
            fallbackView: fallbackView.map { AnyView($0) },
            fallbackPerTrigger: anyViewPerTrigger,
            fallbackBundle: fallbackBundle
        )
    }
    
    /// Creates a configuration with fallback bundle and per-trigger loading settings.
    ///
    /// This convenience method is ideal for apps that:
    /// 1. Use a fallback bundle for rich fallback paywalls
    /// 2. Need different loading behavior for different triggers
    ///
    /// - Parameters:
    ///   - bundleURL: URL to the fallback bundle JSON file
    ///   - globalLoadingBudget: Default loading timeout for all triggers (default: 2.0)
    ///   - triggerSettings: Per-trigger loading customizations as tuples:
    ///     - useLoading: Override whether to show loading (nil = use global)
    ///     - budget: Override loading timeout (nil = use global)
    ///     - view: Custom loading view for this trigger (nil = use global)
    /// - Returns: A configured HeliumFallbackConfig instance
    ///
    /// - Example:
    /// ```swift
    /// let config = HeliumFallbackConfig.withFallbackBundleAndTriggerSettings(
    ///     bundleURL: bundleURL,
    ///     globalLoadingBudget: 2.0,
    ///     triggerSettings: [
    ///         // Disable loading for onboarding
    ///         "onboarding": (useLoading: false, budget: nil, view: nil),
    ///         // Longer timeout for premium upgrade
    ///         "premium_upgrade": (useLoading: true, budget: 5.0, view: nil),
    ///         // Custom loading view for special offer
    ///         "special_offer": (useLoading: true, budget: 3.0, view: MyCustomLoadingView())
    ///     ]
    /// )
    /// ```
    public static func withFallbackBundleAndTriggerSettings(
        bundleURL: URL,
        globalLoadingBudget: TimeInterval = 2.0,
        triggerSettings: [String: (useLoading: Bool?, budget: TimeInterval?, view: (any View)?)] = [:]
    ) -> HeliumFallbackConfig {
        // Convert the convenience tuple format to TriggerLoadingConfig
        var perTriggerConfig: [String: TriggerLoadingConfig] = [:]
        for (trigger, settings) in triggerSettings {
            perTriggerConfig[trigger] = TriggerLoadingConfig(
                useLoadingState: settings.useLoading,
                loadingBudget: settings.budget,
                loadingView: settings.view.map { AnyView($0) }
            )
        }
        
        return HeliumFallbackConfig(
            useLoadingState: true,  // Default to true globally
            loadingBudget: globalLoadingBudget,
            loadingView: nil,
            perTriggerLoadingConfig: perTriggerConfig.isEmpty ? nil : perTriggerConfig,
            fallbackView: nil,
            fallbackPerTrigger: nil,
            fallbackBundle: bundleURL
        )
    }
    
    // MARK: - Helper Methods
    
    /// Get the loading state setting for a specific trigger
    public func useLoadingState(for trigger: String) -> Bool {
        return perTriggerLoadingConfig?[trigger]?.useLoadingState ?? useLoadingState
    }
    
    /// Get the loading budget for a specific trigger
    public func loadingBudget(for trigger: String) -> TimeInterval {
        return perTriggerLoadingConfig?[trigger]?.loadingBudget ?? loadingBudget
    }
    
    /// Get the loading view for a specific trigger
    public func loadingView(for trigger: String) -> AnyView? {
        return perTriggerLoadingConfig?[trigger]?.loadingView ?? loadingView
    }
}
