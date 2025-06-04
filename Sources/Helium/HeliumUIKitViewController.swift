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
    
    let viewType: PaywallOpenViewType
    weak var heliumViewController: HeliumViewController? = nil
    @Published var isOpen: Bool = false
    
    private let useAppearanceToSetIsOpen: Bool
    init(viewType: PaywallOpenViewType, useAppearanceToSetIsOpen: Bool = false) {
        self.viewType = viewType
        self.useAppearanceToSetIsOpen = useAppearanceToSetIsOpen
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }
    
    // Use this to try and prevent unnecessary extra open events.
    // (Extra close events are harder to prevent, since we can't be sure if the paywall is
    // completely closed since onDisappear can potentially be called multiple times.)
    private(set) var firstOnAppearHandled: Bool = false
    
    func handleOnAppear() {
        firstOnAppearHandled = true
        if !useAppearanceToSetIsOpen {
            return
        }
        if !isOpen {
            isOpen = true
        }
    }
    func handleOnDisappear() {
        if !useAppearanceToSetIsOpen {
            return
        }
        if isOpen {
            isOpen = false
        }
    }
    
    @objc private func appWillTerminate() {
        // attempt to dispatch paywallClose analytics event even if user rage quits
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
    static let defaultValue: HeliumPaywallPresentationState = HeliumPaywallPresentationState(viewType: .embedded, useAppearanceToSetIsOpen: true)
}
extension EnvironmentValues {
    var paywallPresentationState: HeliumPaywallPresentationState {
        get { self[HeliumPaywallPresentationStateKey.self] }
        set { self[HeliumPaywallPresentationStateKey.self] = newValue }
    }
}

class HeliumViewController: UIViewController {
    private let contentView: AnyView
    let presentationState = HeliumPaywallPresentationState(viewType: .presented)
    
    init(contentView: AnyView) {
        self.contentView = AnyView(contentView
            .environment(\.paywallPresentationState, presentationState))
        super.init(nibName: nil, bundle: nil)
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
    
    // Only allow portrait paywalls for now
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }
    
}
