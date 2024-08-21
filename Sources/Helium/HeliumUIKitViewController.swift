//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/20/24.
//

import Foundation
import HeliumCore
import SwiftUI
import UIKit

class HeliumViewController: UIViewController {
    let trigger: String
    
    init(trigger: String) {
        self.trigger = trigger
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad();
        
        let configManager = HeliumFetchedConfigManager.shared;
        
        if (configManager.downloadStatus == .notDownloadedYet) {
            return;
        }
        
        var paywallInfo: HeliumPaywallInfo? = nil;
        var clientName: String? = nil;
        
        if (configManager.downloadStatus == HeliumFetchedConfigStatus.downloadSuccess) {
            paywallInfo = configManager.getPaywallInfoForTrigger(trigger);
            clientName = configManager.getClientName();
        }
        
        let baseTemplateView = Helium.shared.getBaseTemplateView(
            clientName: clientName,
            paywallInfo: paywallInfo,
            trigger: trigger
        )
        let modalView = UIHostingController(rootView: baseTemplateView)
        addChild(modalView)
        view.addSubview(modalView.view)
        modalView.view.frame = view.bounds
        modalView.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        modalView.didMove(toParent: self)
    }
}

// Helper class to present the base paywall from anywhere
class HeliumPaywallPresenter {
    static let shared = HeliumPaywallPresenter()
    
    private init() {}
    
    func presentUpsell(trigger: String, from viewController: UIViewController? = nil) {
        let modalVC = HeliumViewController(trigger: trigger)
        modalVC.modalPresentationStyle = .fullScreen
        
        if let presenter = viewController {
            presenter.present(modalVC, animated: true, completion: nil)
        } else {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                findTopMostViewController(rootViewController).present(modalVC, animated: true, completion: nil)
            }
        }
    }
    
    private func findTopMostViewController(_ controller: UIViewController) -> UIViewController {
        let keyWindow = UIApplication.shared.windows.filter {$0.isKeyWindow}.first

        if var topController = keyWindow?.rootViewController {
            while let presentedViewController = topController.presentedViewController {
                topController = presentedViewController
            }
            return topController
        }
        return controller
    }
}
