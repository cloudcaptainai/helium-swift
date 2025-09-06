import Foundation
import SwiftUI

/// Configuration for fallback and loading behavior when paywalls are not immediately available
public struct HeliumFallbackConfig {
    // Loading settings
    public var useLoadingState: Bool = true
    public var loadingBudget: TimeInterval = 2.0
    public var loadingView: AnyView? = nil  // nil = default shimmer
    
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
        fallbackView: AnyView?,
        fallbackPerTrigger: [String: AnyView]?,
        fallbackBundle: URL?,
        onFallback: ((String) -> AnyView?)?
    ) {
        self.useLoadingState = useLoadingState
        self.loadingBudget = loadingBudget
        self.loadingView = loadingView
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
        loadingView: AnyView? = nil
    ) -> HeliumFallbackConfig {
        return HeliumFallbackConfig(
            useLoadingState: useLoadingState,
            loadingBudget: loadingBudget,
            loadingView: loadingView,
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
        loadingView: AnyView? = nil
    ) -> HeliumFallbackConfig {
        var anyViewMap: [String: AnyView] = [:]
        for (key, view) in fallbacks {
            anyViewMap[key] = AnyView(view)
        }
        return HeliumFallbackConfig(
            useLoadingState: useLoadingState,
            loadingBudget: loadingBudget,
            loadingView: loadingView,
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
        loadingView: AnyView? = nil
    ) -> HeliumFallbackConfig {
        return HeliumFallbackConfig(
            useLoadingState: useLoadingState,
            loadingBudget: loadingBudget,
            loadingView: loadingView,
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
        loadingView: AnyView? = nil
    ) -> HeliumFallbackConfig {
        return HeliumFallbackConfig(
            useLoadingState: useLoadingState,
            loadingBudget: loadingBudget,
            loadingView: loadingView,
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
        loadingView: AnyView? = nil
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
            fallbackView: fallbackView.map { AnyView($0) },
            fallbackPerTrigger: anyViewPerTrigger,
            fallbackBundle: fallbackBundle,
            onFallback: onFallback
        )
    }
}
