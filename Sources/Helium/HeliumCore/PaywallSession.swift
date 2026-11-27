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
    var isSecondTry: Bool = false
    let config: PaywallPresentationConfig
    let eventHandlers: PaywallEventHandlers?
    let onEntitled: ((PaywallEntitledEvent) -> Void)?
    let onPaywallNotShown: ((PaywallNotShownReason) -> Void)?
    
    var customPaywallTraits: HeliumUserTraits? {
        return config.customPaywallTraits
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
    let isSecondTry: Bool
    let fallbackType: FallbackPaywallType
    let presentationContext: PaywallPresentationContext
    
    var isFallback: Bool {
        return fallbackType != .notFallback
    }
    
    let paywallInfo: HeliumPaywallInfo?
    let allocationExperimentInfo: ExperimentInfo?
    let allocationConfigId: UUID?
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
        self.isSecondTry = presentationContext.isSecondTry
        self.fallbackType = fallbackType
        self.paywallInfo = paywallInfo
        let fetchedConfig = HeliumFetchedConfigManager.shared.getConfig()
        self.allocationExperimentInfo = fetchedConfig?.extractExperimentInfo(trigger: trigger, paywallInfo: paywallInfo)
        self.allocationConfigId = fetchedConfig?.fetchedConfigID
        self.presentationContext = presentationContext
    }

    /// Returns a copy of this session with the presentation context replaced.
    func withPresentationContext(_ context: PaywallPresentationContext) -> PaywallSession {
        PaywallSession(
            sessionId: self.sessionId,
            trigger: self.trigger,
            paywallInfo: self.paywallInfo,
            fallbackType: self.fallbackType,
            allocationExperimentInfo: self.allocationExperimentInfo,
            allocationConfigId: self.allocationConfigId,
            presentationContext: context,
            isSecondTry: self.isSecondTry
        )
    }

    private init(sessionId: String, trigger: String, paywallInfo: HeliumPaywallInfo?, fallbackType: FallbackPaywallType, allocationExperimentInfo: ExperimentInfo?, allocationConfigId: UUID?, presentationContext: PaywallPresentationContext, isSecondTry: Bool) {
        self.sessionId = sessionId
        self.trigger = trigger
        self.isSecondTry = isSecondTry
        self.fallbackType = fallbackType
        self.paywallInfo = paywallInfo
        self.allocationExperimentInfo = allocationExperimentInfo
        self.allocationConfigId = allocationConfigId
        self.presentationContext = presentationContext
    }
}
