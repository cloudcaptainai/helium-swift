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
            let contentView = Helium.shared.upsellViewForTrigger(trigger: trigger)
            presentPaywall(trigger: trigger, contentView: contentView, from: viewController)
        }
    }
    
    func presentUpsellBeforeLoaded(trigger: String, loadingView: AnyView) {
        Task { @MainActor in
            presentPaywall(trigger: trigger, contentView: loadingView, from: nil)
        }
    }
    func updateUpsellAfterLoad(trigger: String) {
        let contentView = Helium.shared.upsellViewForTrigger(trigger: trigger)
        Task { @MainActor in
            let paywall = paywallsDisplayed.first { $0.trigger == trigger }
            paywall?.updateContent(contentView)
        }
    }
    
    @MainActor
    private func presentPaywall(trigger: String, contentView: AnyView, from viewController: UIViewController? = nil) {
        let modalVC = HeliumViewController(trigger: trigger, contentView: contentView)
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
    
    /// Removes the topmost (top of the stack) paywall found with matching trigger
    @discardableResult
    func hideUpsell(trigger: String, animated: Bool = true) {
        guard let paywallToRemoveIndex = paywallsDisplayed.firstIndex(where: { $0.trigger == trigger }) else {
            return
        }
        let removed = paywallsDisplayed.remove(at: paywallToRemoveIndex)
        Task { @MainActor in
            guard let presenter = removed.presentingViewController else {
                return
            }
            presenter.dismiss(animated: animated)
        }
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
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        let templatName  = paywallInfo?.paywallTemplateName ?? "Unknown"
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallOpen(triggerName: trigger, paywallTemplateName: templatName, viewType: PaywallOpenViewType.presented.rawValue))
    }
    
    private func dispatchCloseEvent(trigger: String) {
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        let templatName  = paywallInfo?.paywallTemplateName ?? "Unknown"
        HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallClose(triggerName: trigger, paywallTemplateName: templatName))
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
