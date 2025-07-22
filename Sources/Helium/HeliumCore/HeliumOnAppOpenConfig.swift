//
//  HeliumOnAppOpenConfig.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 7/21/25.
//

import SwiftUI

public enum HeliumAppEventTrigger : String {
    case onAppInstallTrigger = "on_app_install"
    case onAppLaunchTrigger = "on_app_launch"
    case onAppOpenTrigger = "on_app_open"
    case defaultForAppEvents = "h_default_for_app_events"
}

public struct HeliumOnAppEventConfig {
    var appTrigger: HeliumAppEventTrigger
    var enabled: Bool = true
    var indicateLoading: Bool = false
    var loadingBudgetInSeconds: TimeInterval = 1.5
    var customLoadingView: AnyView? = nil
    
    // Need an explicitly public init for use outside the SDK
    public init(
        appTrigger: HeliumAppEventTrigger,
        enabled: Bool = true,
        indicateLoading: Bool = true,
        loadingBudgetInSeconds: TimeInterval = 1.5,
        customLoadingView: AnyView? = nil
    ) {
        self.appTrigger = appTrigger
        self.enabled = enabled
        self.indicateLoading = indicateLoading
        self.loadingBudgetInSeconds = loadingBudgetInSeconds
        self.customLoadingView = customLoadingView
    }
}

class HeliumOnAppEventConfigManager {
    
    public static let shared = HeliumOnAppEventConfigManager()
    
    var configs: [HeliumOnAppEventConfig] = []
    
    private var startTime: Date?
    private var activeConfig: HeliumOnAppEventConfig?
        
    func startTiming(appTrigger: HeliumAppEventTrigger) {
        if activeConfig != nil {
            // only process one app action at a time
            return
        }
        
        var config = configs.first { $0.appTrigger == appTrigger }
        if config == nil {
            // see if there is a generic config
            var defaultConfigCopy = configs.first { $0.appTrigger == .defaultForAppEvents }
            config = defaultConfigCopy
            config?.appTrigger = appTrigger
        }
        
        guard let config else {
            return
        }
        
        startTime = Date()
        activeConfig = config
        
        if Helium.shared.paywallsLoaded() {
            // already available!
            onBundlesAvailable(skipLoading: true)
            return
        }
        
        if config.indicateLoading {
            HeliumPaywallPresenter.shared.presentUpsellBeforeLoaded(trigger: config.appTrigger.rawValue, loadingView: config.customLoadingView ?? AnyView(LoadingView()))
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
    private func isPastLoadingBudget(config: HeliumOnAppEventConfig) -> Bool {
        let elapsed = getElapsedTime()
        return elapsed > config.loadingBudgetInSeconds
    }
    
    func onBundlesAvailable(skipLoading: Bool = false) {
        guard let config = activeConfig else {
            return
        }
        activeConfig = nil
        let trigger = config.appTrigger.rawValue
        if !config.enabled {
            HeliumPaywallPresenter.shared.hideUpsell(trigger: trigger)
            return
        }
        if isPastLoadingBudget(config: config) {
            print("[Helium] '\(trigger)' trigger not shown; past loading budget (\(getElapsedTime()) seconds > \(config.loadingBudgetInSeconds)).")
            HeliumPaywallPresenter.shared.hideUpsell(trigger: trigger)
            return
        }
        if !Helium.shared.triggerAvailable(trigger: trigger) {
            print("[Helium] '\(trigger)' trigger is not available.")
            HeliumPaywallPresenter.shared.hideUpsell(trigger: trigger)
            return
        }
        if config.indicateLoading && !skipLoading {
            if !Helium.shared.checkShouldShowBeforePresenting(trigger: trigger) {
                HeliumPaywallPresenter.shared.hideUpsell(trigger: trigger)
            } else {
                HeliumPaywallPresenter.shared.updateUpsellAfterLoad(trigger: trigger)
            }
        } else {
            Helium.shared.presentUpsell(trigger: trigger)
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
