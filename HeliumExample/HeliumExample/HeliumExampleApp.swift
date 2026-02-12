//
//  HeliumExampleApp.swift
//  HeliumExample
//
//  Created by Kyle Gorlick on 11/17/25.
//

import Helium
import SwiftUI

@main
struct HeliumExampleApp: App {
    init() {
        // For automated UI tests:
        let loadStateTestTrigger = ProcessInfo.processInfo.environment["LOAD_STATE_TEST_TRIGGER"]
        let fallbackTestMode = ProcessInfo.processInfo.environment["FALLBACK_TEST_MODE"]

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

        if fallbackTestMode == FallbackTestMode.loadingBudget.rawValue {
            Helium.config.defaultLoadingBudget = 1
        }

        // Helium initialize
        Helium.shared.addHeliumEventListener(LogHeliumEventListener.shared)

        let apiKey: String = if fallbackTestMode == FallbackTestMode.downloadFailure.rawValue {
            "invalid_api_key_for_testing"
        } else {
            AppConfig.apiKey
        }

        Helium.shared.initialize(
            apiKey: apiKey
        )

        // For automated UI tests:
        if let loadStateTestTrigger {
            Helium.shared.presentPaywall(trigger: loadStateTestTrigger) { reason in
                print("[Helium Example] loadStateTestTrigger - Could not show paywall. \(reason)")
            }
        }

        // Fallback test modes: auto-present paywall on launch
        if fallbackTestMode == FallbackTestMode.downloadFailure.rawValue {
            Helium.shared.presentPaywall(
                trigger: AppConfig.triggerKey,
                config: PaywallPresentationConfig(loadingBudget: 0)
            ) { reason in
                print("[Helium Example] fallback download_failure - Could not show paywall. \(reason)")
            }
        } else if fallbackTestMode == FallbackTestMode.loadingBudget.rawValue {
            Helium.shared.presentPaywall(trigger: AppConfig.triggerKey) { reason in
                print("[Helium Example] fallback loading_budget - Could not show paywall. \(reason)")
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

enum FallbackTestMode: String {
    case loadingBudget = "loading_budget"
    case downloadFailure = "download_failure"
}
