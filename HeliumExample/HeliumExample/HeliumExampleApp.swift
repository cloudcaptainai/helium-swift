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

        Helium.shared.initialize(
            apiKey: "insert_api_key_here",
            fallbackConfig: fallbackConfig,
        )
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
