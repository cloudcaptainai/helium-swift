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
    var customLoadingView: View? = nil
    
    // Need an explicitly public init for use outside the SDK
    public init(
        enabled: Bool = true,
        indicateLoading: Bool = false,
        loadingBudgetInSeconds: TimeInterval = 1.5,
        customLoadingView: View? = nil
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
            return
        }
        if isPastLoadingBudget() {
            print("[Helium] 'on_app_open' trigger not shown; past loading budget (\(getElapsedTime()) seconds > \(config.loadingBudgetInSeconds)).")
            return
        }
        if !Helium.shared.triggerAvailable(trigger: onAppOpenTrigger) {
            print("[Helium] 'on_app_open' trigger is not available.")
            return
        }
        if config.indicateLoading {
            // todo
        } else {
            Helium.shared.presentUpsell(trigger: onAppOpenTrigger)
        }
    }
    
}
