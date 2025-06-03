//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/20/24.
//

import Foundation
import SwiftUI
import UIKit

public class HeliumPaywallPresentationState: ObservableObject {
    weak var heliumViewController: HeliumViewController? = nil
    @Published var isOpen: Bool = false
    
    private let ignoreAppearDisappear: Bool
    init(ignoreAppearDisappear: Bool = true) {
        self.ignoreAppearDisappear = ignoreAppearDisappear
    }
    
    func handleOnAppear() {
        if ignoreAppearDisappear {
            return
        }
        if !isOpen {
            isOpen = true
        }
    }
    func handleOnDisappear() {
        if ignoreAppearDisappear {
            return
        }
        if isOpen {
            isOpen = false
        }
    }
}

// Use EnvironmentKey so can provide a default value in case paywallPresentationState not set,
// like when using upsell widget directly instead of HeliumViewController.
private struct HeliumPaywallPresentationStateKey: EnvironmentKey {
    // Rely on HeliumViewController/DynamicPaywallModifier if possible to manage isOpen
    // state but if that's not available (ex: the paywall presentation is handled externally)
    // then just use onAppear/onDisappear
    static let defaultValue: HeliumPaywallPresentationState = HeliumPaywallPresentationState(ignoreAppearDisappear: false)
}
extension EnvironmentValues {
    var paywallPresentationState: HeliumPaywallPresentationState {
        get { self[HeliumPaywallPresentationStateKey.self] }
        set { self[HeliumPaywallPresentationStateKey.self] = newValue }
    }
}

class HeliumViewController: UIViewController {
    private let contentView: AnyView
    let presentationState = HeliumPaywallPresentationState()
    
    init(contentView: AnyView) {
        self.contentView = AnyView(contentView
            .environment(\.paywallPresentationState, presentationState))
        super.init(nibName: nil, bundle: nil)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        presentationState.heliumViewController = self
        
        let modalView = UIHostingController(rootView: contentView)
        addChild(modalView)
        view.addSubview(modalView.view)
        modalView.view.frame = view.bounds
        modalView.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        modalView.didMove(toParent: self)
        
        presentationState.isOpen = true
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent {
            HeliumPaywallPresenter.shared.cleanUpPaywall(heliumViewController: self)
            presentationState.isOpen = false
        }
    }
    
    @objc private func appWillTerminate() {
        // attempt to register paywallClose analytics event even if user rage quits
        presentationState.isOpen = false
    }
    
    // Only allow portrait paywalls for now
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }
    
}
