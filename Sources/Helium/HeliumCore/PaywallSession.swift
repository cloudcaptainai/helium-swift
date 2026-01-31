//
//  PaywallSession.swift
//  Helium
//
//  Represents a single paywall presentation session.
//

import Foundation

enum FallbackPaywallType {
    case notFallback
    case fallbackBundle
    case fallbackView
}

/// Presentation context for a single paywall presentation
struct PaywallPresentationContext {
    let config: PaywallPresentationConfig
    let eventHandlers: PaywallEventHandlers?
    let onEntitled: (() -> Void)?
    let onPaywallNotShown: ((PaywallNotShownReason) -> Void)?
    
    func getCustomVariableValues() -> [String: Any] {
        return config.customPaywallTraits ?? [:]
    }
    
    static let empty: PaywallPresentationContext = PaywallPresentationContext(
        config: PaywallPresentationConfig(),
        eventHandlers: nil,
        onEntitled: nil,
        onPaywallNotShown: nil
    )
}

/// Represents a single paywall presentation session.
struct PaywallSession {
    let sessionId: String
    let trigger: String
    let fallbackType: FallbackPaywallType
    let presentationContext: PaywallPresentationContext
    
    private let paywallInfo: HeliumPaywallInfo?
    var paywallInfoWithBackups: HeliumPaywallInfo? {
        if let paywallInfo {
            return paywallInfo
        }
        
        // If for some unexpected reason paywall info not set, try to grab directly
        switch fallbackType {
        case .notFallback, .fallbackView:
            return HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        case .fallbackBundle:
            return HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger)
        }
    }
    
    init(trigger: String, paywallInfo: HeliumPaywallInfo?, fallbackType: FallbackPaywallType, presentationContext: PaywallPresentationContext) {
        self.sessionId = UUID().uuidString
        self.trigger = trigger
        self.fallbackType = fallbackType
        self.paywallInfo = paywallInfo
        self.presentationContext = presentationContext
    }
}
