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
        // (recommended - see Fallbacks and Loading Budgets section)
//        let fallbackBundleURL = Bundle.main.url(forResource: "fallback-bundle", withExtension: "json")
//        let fallbackConfig = HeliumFallbackConfig.withFallbackBundle(fallbackBundleURL)

        Helium.shared.initialize(
            apiKey: "blah",
//            fallbackConfig: fallbackConfig,
        )
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
