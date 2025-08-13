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
    
    @MainActor
    private func presentPaywall(trigger: String, isFallback: Bool, contentView: AnyView, from viewController: UIViewController? = nil) {
        let modalVC = HeliumViewController(trigger: trigger, isFallback: isFallback, contentView: contentView)
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
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallOpen(triggerName: trigger, paywallTemplateName: templateName, viewType: PaywallOpenViewType.presented.rawValue))
    }
    
    private func dispatchCloseEvent(trigger: String) {
        let isFallback = paywallsDisplayed.first { $0.trigger == trigger }?.isFallback ?? false
        let paywallInfo = !isFallback ? HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger) : HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger)
        let templateName = paywallInfo?.paywallTemplateName ?? HELIUM_FALLBACK_PAYWALL_NAME
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallClose(triggerName: trigger, paywallTemplateName: templateName))
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
