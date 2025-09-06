import Foundation
import SwiftUI
import UIKit

class HeliumPaywallPresenter {
    static let shared = HeliumPaywallPresenter()
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }
    
    private var paywallsDisplayed: [HeliumViewController] = []
    
    func presentUpsell(trigger: String, from viewController: UIViewController? = nil) {
        Task { @MainActor in
            let upsellViewResult = Helium.shared.upsellViewResultFor(trigger: trigger)
            let contentView = upsellViewResult.view
            presentPaywall(trigger: trigger, isFallback: upsellViewResult.isFallback, contentView: contentView, from: viewController)
        }
    }
    
    func presentUpsellWithLoadingBudget(trigger: String, from viewController: UIViewController? = nil) {
        Task { @MainActor in
            // Check if paywall is ready
            if Helium.shared.paywallsLoaded() {
                presentUpsell(trigger: trigger, from: viewController)
                return
            }
            
            // Get fallback configuration
            let fallbackConfig = Helium.shared.fallbackConfig
            
            // If loading state disabled, show fallback immediately
            if !fallbackConfig.useLoadingState {
                presentUpsell(trigger: trigger, from: viewController)
                return
            }
            
            // Show loading state
            let loadingView = fallbackConfig.loadingView ?? createDefaultLoadingView()
            presentPaywall(trigger: trigger, isFallback: false, contentView: loadingView, from: viewController, isLoading: true)
            
            // Schedule timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(fallbackConfig.loadingBudget * 1_000_000_000))
                await MainActor.run {
                    // Update to real paywall or fallback if still not ready
                    self.updateLoadingPaywall(trigger: trigger)
                }
            }
            
            // Also listen for download completion
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleDownloadComplete(_:)),
                name: NSNotification.Name("HeliumConfigDownloadComplete"),
                object: nil
            )
        }
    }
    
    @MainActor
    private func updateLoadingPaywall(trigger: String) {
        guard let loadingPaywall = paywallsDisplayed.first(where: { $0.trigger == trigger && $0.isLoading }) else {
            return
        }
        
        let upsellViewResult = Helium.shared.upsellViewResultFor(trigger: trigger)
        loadingPaywall.updateContent(upsellViewResult.view)
        loadingPaywall.isFallback = upsellViewResult.isFallback
        loadingPaywall.isLoading = false
    }
    
    @objc private func handleDownloadComplete(_ notification: Notification) {
        Task { @MainActor in
            // Update any loading paywalls
            for paywall in paywallsDisplayed where paywall.isLoading {
                updateLoadingPaywall(trigger: paywall.trigger)
            }
        }
    }
    
    private func createDefaultLoadingView() -> AnyView {
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
                Color.white
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
    private func presentPaywall(trigger: String, isFallback: Bool, contentView: AnyView, from viewController: UIViewController? = nil, isLoading: Bool = false) {
        let modalVC = HeliumViewController(trigger: trigger, isFallback: isFallback, contentView: contentView, isLoading: isLoading)
        modalVC.modalPresentationStyle = .fullScreen
        
        let presenter = viewController ?? findTopMostViewController()
        presenter.present(modalVC, animated: true)
        
        paywallsDisplayed.append(modalVC)
                
        dispatchOpenEvent(trigger: trigger)
    }
    
    @MainActor
    private func findTopMostViewController() -> UIViewController {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
              var topController = keyWindow.rootViewController else {
            fatalError("No root view controller found")
        }
        
        while let presentedViewController = topController.presentedViewController {
            topController = presentedViewController
        }
        
        return topController
    }
    
    @discardableResult
    func hideUpsell(animated: Bool = true) -> Bool {
        guard let currentPaywall = paywallsDisplayed.popLast(),
              currentPaywall.presentingViewController != nil else {
            return false
        }
        Task { @MainActor in
            currentPaywall.dismiss(animated: animated) { [weak self] in
                self?.dispatchCloseEvent(trigger: currentPaywall.trigger)
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
    
    private func dispatchOpenEvent(trigger: String) {
        let isFallback = paywallsDisplayed.first { $0.trigger == trigger }?.isFallback ?? false
        let paywallInfo = !isFallback ? HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger) : HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger)
        let templateName  = paywallInfo?.paywallTemplateName ?? HELIUM_FALLBACK_PAYWALL_NAME
        HeliumPaywallDelegateWrapper.shared.fireEvent(
            PaywallOpenEvent(
                triggerName: trigger,
                paywallName: templateName,
                viewType: .presented
            )
        )
    }
    
    private func dispatchCloseEvent(trigger: String) {
        let isFallback = paywallsDisplayed.first { $0.trigger == trigger }?.isFallback ?? false
        let paywallInfo = !isFallback ? HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger) : HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger)
        let templateName = paywallInfo?.paywallTemplateName ?? HELIUM_FALLBACK_PAYWALL_NAME
        HeliumPaywallDelegateWrapper.shared.fireEvent(
            PaywallCloseEvent(
                triggerName: trigger,
                paywallName: templateName
            )
        )
    }
    
    private func dispatchCloseForAll(paywallVCs: [HeliumViewController]) {
        for paywallDisplay in paywallVCs {
            dispatchCloseEvent(trigger: paywallDisplay.trigger)
        }
    }
    
    @objc private func appWillTerminate() {
        // attempt to dispatch paywallClose analytics event even if user rage quits
        dispatchCloseForAll(paywallVCs: paywallsDisplayed)
        paywallsDisplayed.removeAll()
    }
    
}
