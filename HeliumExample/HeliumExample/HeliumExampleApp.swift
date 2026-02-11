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
        // For automated UI tests:
        let loadStateTestTrigger = ProcessInfo.processInfo.environment["LOAD_STATE_TEST_TRIGGER"]
        
        // Mock delegate used for UI tests, otherwise default StoreKitDelegate is used
        if ProcessInfo.processInfo.arguments.contains("UI_TESTING_PURCHASE") {
            let mock = MockPaywallDelegate()
            if ProcessInfo.processInfo.arguments.contains("UI_TESTING_RESTORE_SUCCESS") {
                mock.shouldRestoreSucceed = true
            }
            Helium.config.purchaseDelegate = mock
        }
        if loadStateTestTrigger != nil {
            Helium.config.defaultLoadingBudget = 35
        }
        
        // Helium initialize
        
        Helium.shared.addHeliumEventListener(LogHeliumEventListener.shared)
        
        Helium.shared.initialize(
            apiKey: AppConfig.apiKey
        )
        
        // For automated UI tests:
        if let loadStateTestTrigger {
            Helium.shared.presentPaywall(trigger: loadStateTestTrigger) { reason in
                print("[Helium Example] loadStateTestTrigger - Could not show paywall. \(reason)")
            }
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
