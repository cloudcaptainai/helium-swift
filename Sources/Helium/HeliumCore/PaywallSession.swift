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

/// Represents a single paywall presentation session.
struct PaywallSession {
    let sessionId: String
    let trigger: String
    let fallbackType: FallbackPaywallType
    
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
    
    init(trigger: String, paywallInfo: HeliumPaywallInfo?, fallbackType: FallbackPaywallType) {
        self.sessionId = UUID().uuidString
        self.trigger = trigger
        self.fallbackType = fallbackType
        self.paywallInfo = paywallInfo
    }
}
