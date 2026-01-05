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
        // Create fallback configuration with a fallback bundle
        // (recommended - see https://docs.tryhelium.com/guides/fallback-bundle)
        // If you are copying this example code, BE SURE TO DOWNLOAD AND ADJUST THIS CODE TO
        // POINT TO THE CORRECT FILE.
        let fallbackBundleURL = Bundle.main.url(forResource: "fallback-bundle-2026-01-05", withExtension: "json")
        let fallbackConfig = HeliumFallbackConfig.withFallbackBundle(fallbackBundleURL!)

        // Mock delegate used for UI tests, otherwise default StoreKitDelegate is used
        let delegate: HeliumPaywallDelegate? = ProcessInfo.processInfo.arguments.contains("UI_TESTING_PURCHASE")
            ? MockPaywallDelegate()
            : nil

        Helium.shared.initialize(
            apiKey: AppConfig.apiKey,
            heliumPaywallDelegate: delegate,
            fallbackConfig: fallbackConfig
        )
        
        // For UI tests:
        let loadStateTestTrigger = ProcessInfo.processInfo.environment["LOAD_STATE_TEST_TRIGGER"]
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
