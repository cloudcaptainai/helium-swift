import Foundation
import Helium
private final class CoverageListener: HeliumEventListener {
    func onHeliumEvent(event: HeliumEvent) {}
}

enum SdkApiCoverage {
    static let launchArgument = "SDK_API_COVERAGE"
    static let doneKey = "sdkApiCoverageDone"

    @MainActor
    static func runIfRequested() {
            guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
            UserDefaults.standard.set(false, forKey: doneKey)
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
            UserDefaults.standard.set(true, forKey: doneKey)
            }
    }
}
