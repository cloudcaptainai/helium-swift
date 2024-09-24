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
    let trigger: String?
    let paywallTemplateName: String?
    let fallbackPaywall: (any View)?
    
    init(trigger: String, fallbackPaywall: (any View)?) {
        self.trigger = trigger
        self.paywallTemplateName = nil;
        self.fallbackPaywall = fallbackPaywall;
        super.init(nibName: nil, bundle: nil)
    }
    
    init(paywallTemplateName: String, fallbackPaywall: (any View)?) {
        self.trigger = nil;
        self.paywallTemplateName = paywallTemplateName;
        self.fallbackPaywall = fallbackPaywall;
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let configManager = HeliumFetchedConfigManager.shared
        
        if case .notDownloadedYet = configManager.downloadStatus {
            return
        }
        
        var paywallInfo: HeliumPaywallInfo? = nil
        var baseTemplateView: AnyView?
        
        if let trigger = trigger {
            if case .downloadSuccess = configManager.downloadStatus {
                paywallInfo = configManager.getPaywallInfoForTrigger(trigger)
                
                baseTemplateView = Helium.shared.getBaseTemplateView(
                    paywallInfo: paywallInfo,
                    trigger: trigger
                )
            } else if (self.fallbackPaywall != nil) {
                baseTemplateView = AnyView(self.fallbackPaywall!);
            }
            
        } else if let paywallTemplateName = paywallTemplateName {
            let paywallInfo = createDummyHeliumPaywallInfo(paywallTemplateName: paywallTemplateName)
            
            baseTemplateView = Helium.shared.getBaseTemplateView(
                paywallInfo: paywallInfo,
                trigger: "previewing"
            )
        } else {
            return
        }
        
        if (baseTemplateView != nil) {
            let modalView = UIHostingController(rootView: baseTemplateView)
            addChild(modalView)
            view.addSubview(modalView.view)
            modalView.view.frame = view.bounds
            modalView.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            modalView.didMove(toParent: self)
        }
    }
}

// Helper class to present the base paywall from anywhere
class HeliumPaywallPresenter {
    var fallbackPaywall: (any View)?
    
    static let shared = HeliumPaywallPresenter()
    
    private init() {}
    
    func setFallback(fallbackPaywall: any View) {
        self.fallbackPaywall = fallbackPaywall;
    }
    
    func presentUpsell(trigger: String, from viewController: UIViewController? = nil) {
        let modalVC = HeliumViewController(trigger: trigger, fallbackPaywall: fallbackPaywall)
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
    
    func presentUpsell(paywallTemplateName: String, from viewController: UIViewController? = nil) {
        let modalVC = HeliumViewController(paywallTemplateName: paywallTemplateName, fallbackPaywall: fallbackPaywall);
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
