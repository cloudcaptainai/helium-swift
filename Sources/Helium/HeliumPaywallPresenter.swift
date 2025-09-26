import Foundation
import SwiftUI
import UIKit

class HeliumPaywallPresenter {
    static let shared = HeliumPaywallPresenter()
    
    private let configDownloadEventName = NSNotification.Name("HeliumConfigDownloadComplete")
    
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }
    
    private var paywallsDisplayed: [HeliumViewController] = []
    
    func isSecondTryPaywall(trigger: String) -> Bool {
        return paywallsDisplayed.contains {
            $0.isSecondTry
        }
    }
    
    func presentUpsell(trigger: String, isSecondTry: Bool = false, from viewController: UIViewController? = nil) {
        Task { @MainActor in
            let upsellViewResult = Helium.shared.upsellViewResultFor(trigger: trigger)
            guard let contentView = upsellViewResult.view else {
                HeliumPaywallDelegateWrapper.shared.fireEvent(
                    PaywallOpenFailedEvent(
                        triggerName: trigger,
                        paywallName: upsellViewResult.templateName ?? "unknown",
                        error: "No paywall for trigger and no fallback available when present called."
                    )
                )
                return
            }
            presentPaywall(trigger: trigger, isFallback: upsellViewResult.isFallback, isSecondTry: isSecondTry, contentView: contentView, from: viewController)
        }
    }
    
    func presentUpsellWithLoadingBudget(trigger: String, from viewController: UIViewController? = nil) {
        if !paywallsDisplayed.isEmpty {
            // Only allow one paywall to be presented at a time. (Exception being second try paywalls.)
            print("[Helium] A paywall is already being presented.")
            HeliumPaywallDelegateWrapper.shared.fireEvent(
                PaywallOpenFailedEvent(
                    triggerName: trigger,
                    paywallName: Helium.shared.getPaywallInfo(trigger: trigger)?.paywallTemplateName ?? "unknown",
                    error: "A paywall is already being presented."
                )
            )
            return
        }
        
        Task { @MainActor in
            // Check if paywall is ready
            if Helium.shared.paywallsLoaded() {
                presentUpsell(trigger: trigger, from: viewController)
                return
            }
            
            // Get fallback configuration
            let fallbackConfig = Helium.shared.fallbackConfig
            
            // Get trigger-specific loading configuration
            let useLoading = fallbackConfig?.useLoadingState(for: trigger) ?? false
            let loadingBudget = fallbackConfig?.loadingBudget(for: trigger) ?? 0
            let triggerLoadingView = fallbackConfig?.loadingView(for: trigger)
            
            // If loading state disabled for this trigger, show fallback immediately
            if !useLoading || Helium.shared.getDownloadStatus() != .inProgress {
                presentUpsell(trigger: trigger, from: viewController)
                return
            }
            
            // Get background config from fallback bundle if available
            let fallbackBgConfig = HeliumFallbackViewManager.shared.getBackgroundConfigForTrigger(trigger)
            
            // Show loading state with trigger-specific or default loading view
            let loadingView = triggerLoadingView ?? createDefaultLoadingView(backgroundConfig: fallbackBgConfig)
            presentPaywall(trigger: trigger, isFallback: false, contentView: loadingView, from: viewController, isLoading: true)
            
            // Schedule timeout with trigger-specific budget
            Task {
                try? await Task.sleep(nanoseconds: UInt64(loadingBudget * 1_000_000_000))
                await MainActor.run {
                    // Update to real paywall or fallback if still not ready
                    self.updateLoadingPaywall(trigger: trigger)
                    NotificationCenter.default.removeObserver(self, name: configDownloadEventName, object: nil)
                }
            }
            
            // Also listen for download completion
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleDownloadComplete(_:)),
                name: configDownloadEventName,
                object: nil
            )
        }
    }
    
    @MainActor
    private func updateLoadingPaywall(trigger: String) {
        guard let loadingPaywall = paywallsDisplayed.first(where: { $0.trigger == trigger && $0.isLoading }) else {
            return
        }
        
        if Helium.shared.skipPaywallIfNeeded(trigger: trigger) {
            hideUpsell()
            return
        }
        
        let upsellViewResult = Helium.shared.upsellViewResultFor(trigger: trigger)
        guard let upsellView = upsellViewResult.view else {
            hideUpsell {
                HeliumPaywallDelegateWrapper.shared.fireEvent(
                    PaywallOpenFailedEvent(
                        triggerName: trigger,
                        paywallName: upsellViewResult.templateName ?? "unknown",
                        error: "No paywall for trigger and no fallback available after load complete."
                    )
                )
            }
            return
        }
        loadingPaywall.updateContent(upsellView, isFallback: upsellViewResult.isFallback, isLoading: false)
        
        // Dispatch the official open event
        dispatchOpenEvent(paywallVC: loadingPaywall)
    }
    
    @objc private func handleDownloadComplete(_ notification: Notification) {
        Task { @MainActor in
            // Update any loading paywalls
            for paywall in paywallsDisplayed where paywall.isLoading {
                updateLoadingPaywall(trigger: paywall.trigger)
            }
        }
        NotificationCenter.default.removeObserver(self, name: configDownloadEventName, object: nil)
    }
    
    private func createDefaultLoadingView(backgroundConfig: BackgroundConfig? = nil) -> AnyView {
        // Use shimmer view to match the app open PR approach
        let defaultShimmerConfig = JSON([
            "layout": [
                "type": "vStack",
                "spacing": 20,
                "content": [
                    [
                        "type": "element",
                        "content": [
                            "elementType": "rectangle",
                            "width": 80,
                            "height": 15,
                            "cornerRadius": 8
                        ]
                    ],
                    [
                        "type": "element",
                        "content": [
                            "elementType": "rectangle",
                            "width": 90,
                            "height": 40,
                            "cornerRadius": 12
                        ]
                    ],
                    [
                        "type": "hStack",
                        "spacing": 10,
                        "content": [
                            [
                                "type": "element",
                                "content": [
                                    "elementType": "rectangle",
                                    "width": 40,
                                    "height": 60,
                                    "cornerRadius": 8
                                ]
                            ],
                            [
                                "type": "element",
                                "content": [
                                    "elementType": "rectangle",
                                    "width": 40,
                                    "height": 60,
                                    "cornerRadius": 8
                                ]
                            ]
                        ]
                    ],
                    [
                        "type": "element",
                        "content": [
                            "elementType": "rectangle",
                            "width": 80,
                            "height": 15,
                            "cornerRadius": 8
                        ]
                    ]
                ]
            ]
        ])
        
        return AnyView(
            ZStack {
                // Use provided background config or default to white
                if let bgConfig = backgroundConfig {
                    bgConfig.makeBackgroundView()
                } else {
                    Color.white
                }
                
                VStack {
                    Spacer()
                    EmptyView()
                        .shimmer(config: defaultShimmerConfig)
                    Spacer()
                }
            }
            .edgesIgnoringSafeArea(.all)
        )
    }
    
    @MainActor
    private func presentPaywall(trigger: String, isFallback: Bool, isSecondTry: Bool = false, contentView: AnyView, from viewController: UIViewController? = nil, isLoading: Bool = false) {
        let modalVC = HeliumViewController(trigger: trigger, isFallback: isFallback, isSecondTry: isSecondTry, contentView: contentView, isLoading: isLoading)
        modalVC.modalPresentationStyle = .fullScreen
        
        guard let presenter = viewController ?? findTopMostViewController() else {
            // Failed to find a view controller to present on - dispatch open failed event
            HeliumPaywallDelegateWrapper.shared.fireEvent(
                PaywallOpenFailedEvent(
                    triggerName: trigger,
                    paywallName: Helium.shared.getPaywallInfo(trigger: trigger)?.paywallTemplateName ?? "unknown",
                    error: "No root view controller found"
                )
            )
            return
        }
        presenter.present(modalVC, animated: true)
        
        paywallsDisplayed.append(modalVC)

        dispatchOpenEvent(paywallVC: modalVC)
    }
    
    @MainActor
    private func findTopMostViewController() -> UIViewController? {
        guard let activeWindow = findActiveWindow(),
              var topController = activeWindow.rootViewController else {
            return nil
        }
        
        while let presentedViewController = topController.presentedViewController {
            topController = presentedViewController
        }
        
        return topController
    }
    @MainActor
    private func findActiveWindow() -> UIWindow? {
        if let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            return windowScene.windows.first { $0.isKeyWindow } ?? windowScene.windows.first
        }
        
        if let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundInactive }) as? UIWindowScene {
            return windowScene.windows.first { $0.isKeyWindow } ?? windowScene.windows.first
        }
        
        let allWindows = UIApplication.shared.connectedScenes.flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
        return allWindows.first { $0.isKeyWindow } ?? allWindows.first
    }
    
    @discardableResult
    func hideUpsell(animated: Bool = true, overrideCloseEvent: (() -> Void)? = nil) -> Bool {
        guard let currentPaywall = paywallsDisplayed.popLast(),
              currentPaywall.presentingViewController != nil else {
            return false
        }
        Task { @MainActor in
            currentPaywall.dismiss(animated: animated) { [weak self] in
                if let overrideCloseEvent {
                    overrideCloseEvent()
                } else {
                    self?.dispatchCloseEvent(paywallVC: currentPaywall)
                }
            }
        }
        return true
    }
    
    func hideAllUpsells(onComplete: (() -> Void)? = nil) {
        if paywallsDisplayed.isEmpty {
            onComplete?()
            return
        }
        var paywallsRemoved = paywallsDisplayed
        Task { @MainActor in
            // Have the topmost paywall get dismissed by its presenter which should dismiss all the others,
            // since they must have ultimately be presented by the topmost paywall if you go all the way up.
            paywallsDisplayed.first?.presentingViewController?.dismiss(animated: true) { [weak self] in
                onComplete?()
                self?.dispatchCloseForAll(paywallVCs: paywallsRemoved)
            }
            paywallsDisplayed.removeAll()
        }
    }
    
    func cleanUpPaywall(heliumViewController: HeliumViewController) {
        dispatchCloseForAll(paywallVCs: paywallsDisplayed.filter { $0 === heliumViewController })
        paywallsDisplayed.removeAll { $0 === heliumViewController }
    }
    
    private func dispatchOpenEvent(paywallVC: HeliumViewController) {
        dispatchOpenOrCloseEvent(openEvent: true, paywallVC: paywallVC)
    }
    
    private func dispatchCloseEvent(paywallVC: HeliumViewController) {
        dispatchOpenOrCloseEvent(openEvent: false, paywallVC: paywallVC)
    }
    
    private func dispatchOpenOrCloseEvent(openEvent: Bool, paywallVC: HeliumViewController) {
        if paywallVC.isLoading {
            return // don't fire an event in this case
        }
        let trigger = paywallVC.trigger
        let isFallback = paywallVC.isFallback
        let paywallInfo = !isFallback ? HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger) : HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger)
        let templateBackupName = isFallback ? HELIUM_FALLBACK_PAYWALL_NAME : "unknown"
        let templateName = paywallInfo?.paywallTemplateName ?? templateBackupName
        
        let event: HeliumEvent
        if openEvent {
            let loadTimeTakenMS = paywallVC.loadTimeTakenMS
            let loadingBudget = Helium.shared.fallbackConfig?.loadingBudget(for: trigger)
            var loadingBudgetMS: UInt64? = nil
            if loadTimeTakenMS != nil, let loadingBudget {
                loadingBudgetMS = UInt64(loadingBudget * 1000)
            }
            event = PaywallOpenEvent(
                triggerName: trigger,
                paywallName: templateName,
                viewType: .presented,
                loadTimeTakenMS: loadTimeTakenMS,
                loadingBudgetMS: loadingBudgetMS
            )
        } else {
            event = PaywallCloseEvent(
                triggerName: trigger,
                paywallName: templateName
            )
        }
        HeliumPaywallDelegateWrapper.shared.fireEvent(event)
    }
    
    private func dispatchCloseForAll(paywallVCs: [HeliumViewController]) {
        for paywallDisplay in paywallVCs {
            dispatchCloseEvent(paywallVC: paywallDisplay)
        }
    }
    
    @objc private func appWillTerminate() {
        // attempt to dispatch paywallClose analytics event even if user rage quits
        dispatchCloseForAll(paywallVCs: paywallsDisplayed)
        paywallsDisplayed.removeAll()
    }
    
}
