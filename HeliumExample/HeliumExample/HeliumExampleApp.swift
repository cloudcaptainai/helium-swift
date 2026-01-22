//
//  HeliumExampleApp.swift
//  HeliumExample
//
//  Created by Kyle Gorlick on 11/17/25.
//

import SwiftUI
import Helium

@main
struct HeliumExampleApp: App {
    init() {
        // For UI tests:
        let loadStateTestTrigger = ProcessInfo.processInfo.environment["LOAD_STATE_TEST_TRIGGER"]
        
        // Create fallback configuration with a fallback bundle
        // (recommended - see https://docs.tryhelium.com/guides/fallback-bundle)
        // If you are copying this example code, BE SURE TO DOWNLOAD AND ADJUST THIS CODE TO
        // POINT TO THE CORRECT FILE.
        let fallbackBundleURL = Bundle.main.url(forResource: "fallback-bundle-2026-01-05", withExtension: "json")
        let fallbackConfig = HeliumFallbackConfig.withFallbackBundle(
            fallbackBundleURL!,
            loadingBudget: loadStateTestTrigger != nil ? 35 : HeliumFallbackConfig.defaultLoadingBudget
        )

        // Mock delegate used for UI tests, otherwise default StoreKitDelegate is used
        let delegate: HeliumPaywallDelegate? = ProcessInfo.processInfo.arguments.contains("UI_TESTING_PURCHASE")
            ? MockPaywallDelegate()
            : nil
        
        Helium.shared.addHeliumEventListener(LogHeliumEventListener.shared)
        
        Helium.setLogLevel(.debug)

        Helium.shared.initialize(
            apiKey: AppConfig.apiKey,
            heliumPaywallDelegate: delegate,
            fallbackConfig: fallbackConfig
        )
        
        // For UI tests:
        if let loadStateTestTrigger {
            Helium.shared.presentUpsell(trigger: loadStateTestTrigger)
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
    
}

fileprivate class LogHeliumEventListener: HeliumEventListener {
    static let shared = LogHeliumEventListener()

    func onHeliumEvent(event: any HeliumEvent) {
        print("helium event - \(event.toDictionary())")
    }
}
