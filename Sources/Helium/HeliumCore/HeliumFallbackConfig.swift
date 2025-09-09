import Foundation
import SwiftUI

/// Per-trigger loading configuration
public struct TriggerLoadingConfig {
    public var useLoadingState: Bool?  // nil = use global default
    public var loadingBudget: TimeInterval?  // nil = use global default
    public var loadingView: AnyView?  // nil = use global default
    
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

/// Configuration for fallback and loading behavior when paywalls are not immediately available
public struct HeliumFallbackConfig {
    // Loading settings
    public var useLoadingState: Bool = true
    public var loadingBudget: TimeInterval = 2.0
    public var loadingView: AnyView? = nil  // nil = default shimmer
    
    // Per-trigger loading overrides
    public var perTriggerLoadingConfig: [String: TriggerLoadingConfig]? = nil
    
    // Fallback options (checked in priority order)
    public var onFallback: ((String) -> AnyView?)? = nil
    public var fallbackPerTrigger: [String: AnyView]? = nil
    public var fallbackBundle: URL? = nil
    public var fallbackView: AnyView? = nil
    
    // Private initializer to prevent creating without fallback
    private init(
        useLoadingState: Bool,
        loadingBudget: TimeInterval,
        loadingView: AnyView?,
        perTriggerLoadingConfig: [String: TriggerLoadingConfig]?,
        fallbackView: AnyView?,
        fallbackPerTrigger: [String: AnyView]?,
        fallbackBundle: URL?,
        onFallback: ((String) -> AnyView?)?
    ) {
        self.useLoadingState = useLoadingState
        self.loadingBudget = loadingBudget
        self.loadingView = loadingView
        self.perTriggerLoadingConfig = perTriggerLoadingConfig
        self.fallbackView = fallbackView
        self.fallbackPerTrigger = fallbackPerTrigger
        self.fallbackBundle = fallbackBundle
        self.onFallback = onFallback
    }
    
    /// Creates config with a single fallback view
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
            fallbackBundle: nil,
            onFallback: nil
        )
    }
    
    /// Creates config with per-trigger fallback views
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
            fallbackBundle: nil,
            onFallback: nil
        )
    }
    
    /// Creates config with fallback bundle URL
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
            fallbackBundle: url,
            onFallback: nil
        )
    }
    
    /// Creates config with dynamic fallback handler
    public static func withFallbackHandler(
        _ handler: @escaping (String) -> AnyView?,
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
            fallbackBundle: nil,
            onFallback: handler
        )
    }
    
    /// Creates config with multiple fallback mechanisms
    public static func withMultipleFallbacks(
        fallbackView: (any View)? = nil,
        fallbackPerTrigger: [String: any View]? = nil,
        fallbackBundle: URL? = nil,
        onFallback: ((String) -> AnyView?)? = nil,
        useLoadingState: Bool = true,
        loadingBudget: TimeInterval = 2.0,
        loadingView: AnyView? = nil,
        perTriggerLoadingConfig: [String: TriggerLoadingConfig]? = nil
    ) -> HeliumFallbackConfig? {
        // Require at least one fallback mechanism
        guard fallbackView != nil || fallbackPerTrigger != nil || fallbackBundle != nil || onFallback != nil else {
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
            fallbackBundle: fallbackBundle,
            onFallback: onFallback
        )
    }
    
    /// Creates config with fallback bundle and per-trigger loading settings
    /// This is a convenience method for the most common use case
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
            fallbackBundle: bundleURL,
            onFallback: nil
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
