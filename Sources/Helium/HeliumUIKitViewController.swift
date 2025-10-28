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
    var isOpen: Bool = false // only used by .embedded and .triggered
    
    private let useAppearanceToSetIsOpen: Bool
    init(viewType: PaywallOpenViewType, useAppearanceToSetIsOpen: Bool = false) {
        self.viewType = viewType
        self.useAppearanceToSetIsOpen = useAppearanceToSetIsOpen
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
    let trigger: String
    private(set) var fallbackReason: PaywallUnavailableReason? = nil
    var isFallback: Bool {
        fallbackReason != nil
    }
    private(set) var isLoading: Bool
    let isSecondTry: Bool
    private var contentView: AnyView
    private var hostingController: UIHostingController<AnyView>?
    let presentationState = HeliumPaywallPresentationState(viewType: .presented)
    
    var customWindow: UIWindow?
    
    private let loadStartTime: DispatchTime?
    private var displayTime: DispatchTime? = nil
    
    init(trigger: String, fallbackReason: PaywallUnavailableReason?, isSecondTry: Bool, contentView: AnyView, isLoading: Bool = false) {
        self.trigger = trigger
        self.fallbackReason = fallbackReason
        self.isSecondTry = isSecondTry
        self.isLoading = isLoading
        self.contentView = AnyView(contentView
            .environment(\.paywallPresentationState, presentationState))
        if isLoading {
            loadStartTime = DispatchTime.now()
        } else {
            loadStartTime = nil
            displayTime = DispatchTime.now()
        }
        super.init(nibName: nil, bundle: nil)
    }
    
    func updateContent(_ newContent: AnyView, fallbackReason: PaywallUnavailableReason?, isLoading: Bool) {
        self.contentView = AnyView(newContent
            .environment(\.paywallPresentationState, presentationState))
        
        // Update the hosting controller's root view
        hostingController?.rootView = self.contentView
        
        let completedLoading = !isLoading && self.isLoading
        self.fallbackReason = fallbackReason
        self.isLoading = isLoading
        if completedLoading {
            displayTime = DispatchTime.now()
        }
    }
    
    var loadTimeTakenMS: UInt64? {
        if let loadStartTime, let displayTime {
            return UInt64(Double(displayTime.uptimeNanoseconds - loadStartTime.uptimeNanoseconds) / 1_000_000.0)
        }
        return nil
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // This should never be called due to @available(*, unavailable)
        // But if it somehow is, return nil instead of crashing
        return nil
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        presentationState.heliumViewController = self
        
        let modalView = UIHostingController(rootView: contentView)
        self.hostingController = modalView
        addChild(modalView)
        view.addSubview(modalView.view)
        modalView.view.frame = view.bounds
        modalView.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        modalView.didMove(toParent: self)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent {
            HeliumPaywallPresenter.shared.cleanUpPaywall(heliumViewController: self)
        }
    }
    
    // Only allow portrait paywalls for now
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }
    
}
