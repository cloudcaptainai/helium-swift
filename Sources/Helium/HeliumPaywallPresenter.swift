import Foundation
import SwiftUI
import UIKit
import HeliumCore

class HeliumPaywallPresenter {
    static let shared = HeliumPaywallPresenter()
    private init() {}
    
    func presentUpsell(trigger: String, from viewController: UIViewController? = nil) {
        let contentView = Helium.shared.upsellViewForTrigger(trigger: trigger);
        presentPaywall(contentView: contentView, from: viewController);
    }
    
    private func presentPaywall(contentView: AnyView, from viewController: UIViewController? = nil) {
        let modalVC = HeliumViewController(contentView: contentView)
        modalVC.modalPresentationStyle = .fullScreen
        
        let presenter = viewController ?? findTopMostViewController()
        presenter.present(modalVC, animated: true)
    }
    
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
}
