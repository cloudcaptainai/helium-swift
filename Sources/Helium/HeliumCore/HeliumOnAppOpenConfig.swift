//
//  HeliumOnAppOpenConfig.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 7/21/25.
//

import SwiftUI

public struct HeliumOnAppOpenConfig {
    var enabled: Bool = true
    var indicateLoading: Bool = false
    var loadingBudgetInSeconds: TimeInterval = 1.5
    var customLoadingView: AnyView? = nil
    
    // Need an explicitly public init for use outside the SDK
    public init(
        enabled: Bool = true,
        indicateLoading: Bool = false,
        loadingBudgetInSeconds: TimeInterval = 1.5,
        customLoadingView: AnyView? = nil
    ) {
        self.enabled = enabled
        self.indicateLoading = indicateLoading
        self.loadingBudgetInSeconds = loadingBudgetInSeconds
        self.customLoadingView = customLoadingView
    }
}

class HeliumOnAppOpenConfigManager {
    private let onAppOpenTrigger: String = "on_app_open"
    
    public static let shared = HeliumOnAppOpenConfigManager()
    
    var config: HeliumOnAppOpenConfig = .init(enabled: false)
    
    private var startTime: Date?
        
    func startTiming() {
        startTime = Date()
        
        if config.indicateLoading {
            HeliumPaywallPresenter.shared.presentUpsellBeforeLoaded(trigger: onAppOpenTrigger, loadingView: config.customLoadingView ?? AnyView(LoadingView()))
        }
    }
    
    /// Get the elapsed time in seconds since timing started
    /// - Returns: TimeInterval representing seconds elapsed, or 0 if not started
    private func getElapsedTime() -> TimeInterval {
        guard let startTime = startTime else {
            return 0
        }
        return Date().timeIntervalSince(startTime)
    }
    
    /// Check if the elapsed time has exceeded the loading budget
    /// - Returns: true if past loading budget, false otherwise
    private func isPastLoadingBudget() -> Bool {
        let elapsed = getElapsedTime()
        return elapsed > config.loadingBudgetInSeconds
    }
    
    func onBundlesAvailable() {
        if !config.enabled {
            HeliumPaywallPresenter.shared.hideUpsell(trigger: onAppOpenTrigger)
            return
        }
        if isPastLoadingBudget() {
            print("[Helium] 'on_app_open' trigger not shown; past loading budget (\(getElapsedTime()) seconds > \(config.loadingBudgetInSeconds)).")
            HeliumPaywallPresenter.shared.hideUpsell(trigger: onAppOpenTrigger)
            return
        }
        if !Helium.shared.triggerAvailable(trigger: onAppOpenTrigger) {
            print("[Helium] 'on_app_open' trigger is not available.")
            HeliumPaywallPresenter.shared.hideUpsell(trigger: onAppOpenTrigger)
            return
        }
        if config.indicateLoading {
            if !Helium.shared.checkShouldShowBeforePresenting(trigger: onAppOpenTrigger) {
                HeliumPaywallPresenter.shared.hideUpsell(trigger: onAppOpenTrigger)
            } else {
                HeliumPaywallPresenter.shared.updateUpsellAfterLoad(trigger: onAppOpenTrigger)
            }
        } else {
            Helium.shared.presentUpsell(trigger: onAppOpenTrigger)
        }
    }
    
}

fileprivate struct LoadingView: View {
    var body: some View {
        ProgressView()
            .scaleEffect(1.5) // Make it slightly larger
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
