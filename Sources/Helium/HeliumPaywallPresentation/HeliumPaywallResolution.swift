//
//  HeliumPaywallResolution.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 3/10/26.
//

import SwiftUI

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

extension PaywallPresentationConfig {
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
