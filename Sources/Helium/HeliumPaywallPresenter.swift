import Foundation
import SwiftUI
import UIKit

class HeliumPaywallPresenter {
    static let shared = HeliumPaywallPresenter()
    private init() {}
    
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
        let modalVC = HeliumViewController(contentView: contentView)
        modalVC.modalPresentationStyle = .fullScreen
        modalVC.trigger = trigger
        
        let presenter = viewController ?? findTopMostViewController()
        presenter.present(modalVC, animated: true)
        
        paywallsDisplayed.append(modalVC)
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
            currentPaywall.dismiss(animated: animated)
        }
        return true
    }
    
    func hideAllUpsells(onComplete: (() -> Void)? = nil) {
        if paywallsDisplayed.isEmpty {
            onComplete?()
            return
        }
        Task { @MainActor in
            // Have the topmost paywall get dismissed by its presenter which should dismiss all the others,
            // since they must have ultimately be presented by the topmost paywall if you go all the way up.
            paywallsDisplayed.first?.presentingViewController?.dismiss(animated: true, completion: onComplete)
            paywallsDisplayed.removeAll()
        }
    }
    
    func cleanUpPaywall(heliumViewController: HeliumViewController) {
        paywallsDisplayed.removeAll { $0 === heliumViewController }
    }
    
}
