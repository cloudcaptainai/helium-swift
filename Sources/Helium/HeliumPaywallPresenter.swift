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
            presentPaywall(contentView: contentView, from: viewController)
        }
    }
    
    @MainActor
    private func presentPaywall(contentView: AnyView, from viewController: UIViewController? = nil) {
        let modalVC = HeliumViewController(contentView: contentView)
        modalVC.modalPresentationStyle = .fullScreen
        
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
    
    @discardableResult
    func hideUpsell(animated: Bool = true) -> Bool {
        Task { @MainActor in
            guard let currentPaywall = paywallsDisplayed.popLast(),
                  currentPaywall.presentingViewController != nil else {
                return false
            }
            
            currentPaywall.dismiss(animated: animated)
            return true
        }
        return true
    }
    
    func hideAllUpsells() {
        Task { @MainActor in
            // Have the topmost paywall get dismissed by its presenter which should dismiss all the others,
            // since they must have ultimately be presented by the topmost paywall if you go all the way up.
            paywallsDisplayed.first?.presentingViewController?.dismiss(animated: true)
            paywallsDisplayed.removeAll()
        }
    }
    
    func cleanUpPaywall(heliumViewController: HeliumViewController) {
        paywallsDisplayed.removeAll { $0 === heliumViewController }
    }
    
}
