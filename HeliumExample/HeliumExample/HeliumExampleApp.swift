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
        configureHelium()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    Helium.shared.handleURL(url)
                }
        }
    }
    
    private func configureHelium() {
        let loadStateTestTrigger = ProcessInfo.processInfo.environment["LOAD_STATE_TEST_TRIGGER"]
        let fallbackTestMode = ProcessInfo.processInfo.environment["FALLBACK_TEST_MODE"]
        preInitializeTestSetup(loadStateTestTrigger: loadStateTestTrigger, fallbackTestMode: fallbackTestMode)
        
        let apiKey: String = if fallbackTestMode == FallbackTestMode.downloadFailure.rawValue {
            "invalid_api_key_for_testing"
        } else {
            AppConfig.apiKey
        }
        
        Helium.config.enableExternalWebCheckout(redirectURL: "heliumexamplestripe://openapp", paymentProcessors: .all)
        
        Helium.shared.initialize(
            apiKey: apiKey
        )
        
        postInitializeTestSetup(loadStateTestTrigger: loadStateTestTrigger, fallbackTestMode: fallbackTestMode)
    }
    
    // MARK: - Automated UI Tests Setup
    
    private func preInitializeTestSetup(loadStateTestTrigger: String?, fallbackTestMode: String?) {

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
    }
    
    private func postInitializeTestSetup(loadStateTestTrigger: String?, fallbackTestMode: String?) {
        if ProcessInfo.processInfo.arguments.contains("SDK_API_COVERAGE") {
            UserDefaults.standard.set(false, forKey: "sdkApiCoverageDone")
            runSdkApiCoverage()
        }
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
}

enum FallbackTestMode: String {
    case loadingBudget = "loading_budget"
    case downloadFailure = "download_failure"
}

private final class CoverageListener: HeliumEventListener {
    func onHeliumEvent(event: HeliumEvent) {}
}

@MainActor
private func runSdkApiCoverage() {
    Task {
        let trigger = AppConfig.triggerKey
        let listener = CoverageListener()
        Helium.shared.addHeliumEventListener(listener)
        Helium.shared.removeHeliumEventListener(listener)
        Helium.shared.addHeliumEventListener(listener)
        Helium.shared.removeAllHeliumEventListeners()
        Helium.identify.userId = "coverage-user"
        Helium.identify.revenueCatAppUserId = "coverage-rc"
        Helium.identify.thirdPartyAnalyticsAnonymousId = "coverage-anon"
        Helium.identify.appAccountToken = UUID()
        Helium.identify.setUserTraits(HeliumUserTraits(["plan": "pro"]))
        Helium.identify.setUserTraits(["plan": "pro"])
        Helium.identify.addUserTraits(HeliumUserTraits(["age": 1]))
        Helium.identify.addUserTraits(["age": 1])
        HeliumSdkConfig.shared.setWrapperSdkInfo(sdk: "coverage", version: "0")
        Helium.config.enableExternalWebCheckout(successURL: "heliumexamplestripe://openapp", cancelURL: "heliumexamplestripe://openapp", paymentProcessors: .all)
        Helium.config.disableExternalWebCheckout()
        Helium.config.enableExternalWebCheckout(redirectURL: "heliumexamplestripe://openapp", paymentProcessors: .all)
        _ = Helium.shared.handleURL(URL(string: "heliumexamplestripe://openapp?transactionId=coverage")!)
        _ = Helium.shared.canShowPaywallFor(trigger: trigger)
        _ = Helium.shared.getPaywallInfo(trigger: trigger)
        _ = Helium.shared.upsellViewForTrigger(trigger: trigger)
        _ = try? await Helium.shared.createStripePortalSession(returnUrl: "https://example.com")
        _ = try? await Helium.shared.createPaddlePortalSession()
        _ = await Helium.shared.getStripeCustomerId()
        _ = await Helium.shared.getPaddleCustomerId()
        Helium.shared.resetStripeEntitlements()
        Helium.shared.resetPaddleEntitlements()
        Helium.shared.initialize(apiKey: AppConfig.apiKey)
        Helium.resetHelium(autoInitialize: true)
        try? await Task.sleep(for: .seconds(8))
        Helium.shared.presentPaywall(trigger: trigger) { _ in }
        try? await Task.sleep(for: .seconds(6))
        _ = Helium.shared.hidePaywall()
        try? await Task.sleep(for: .seconds(2))
        Helium.shared.presentPaywall(trigger: trigger, onEntitled: {}) { _ in }
        try? await Task.sleep(for: .seconds(6))
        Helium.shared.hideAllPaywalls()
        try? await Task.sleep(for: .seconds(2))
        _ = Helium.shared.handleDeepLink(URL(string: "helium://helium-test?trigger=\(trigger)"))
        try? await Task.sleep(for: .seconds(6))
        Helium.shared.hideAllPaywalls()
        try? await Task.sleep(for: .seconds(2))
        UserDefaults.standard.set(true, forKey: "sdkApiCoverageDone")
    }
}
