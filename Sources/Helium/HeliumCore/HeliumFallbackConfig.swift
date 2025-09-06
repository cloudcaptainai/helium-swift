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
    
    // Simple initializer with all defaults
    public init(
        useLoadingState: Bool = true,
        loadingBudget: TimeInterval = 2.0,
        loadingView: AnyView? = nil,
        fallbackView: AnyView? = nil,
        fallbackPerTrigger: [String: AnyView]? = nil,
        fallbackBundle: URL? = nil,
        onFallback: ((String) -> AnyView?)? = nil
    ) {
        self.useLoadingState = useLoadingState
        self.loadingBudget = loadingBudget
        self.loadingView = loadingView
        self.fallbackView = fallbackView
        self.fallbackPerTrigger = fallbackPerTrigger
        self.fallbackBundle = fallbackBundle
        self.onFallback = onFallback
    }
    
    /// Default configuration with 2 second loading budget and shimmer
    public static let `default` = HeliumFallbackConfig()
    
    /// No loading state - goes straight to fallback
    public static let noLoading = HeliumFallbackConfig(useLoadingState: false)
}
