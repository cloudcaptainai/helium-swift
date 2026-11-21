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
    var isInline: Bool { viewType != .presented }
    
    init(viewType: PaywallOpenViewType) {
        self.viewType = viewType
    }
    
}

// Use EnvironmentKey so can provide a default value in case paywallPresentationState not set,
// like when using upsell widget directly instead of HeliumViewController.
private struct HeliumPaywallPresentationStateKey: EnvironmentKey {
    static let defaultValue = HeliumPaywallPresentationState(viewType: .embedded)
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
    private var contentView: AnyView
    private var hostingController: UIHostingController<AnyView>?
    let presentationState = HeliumPaywallPresentationState(viewType: .presented)
    
    var paywallSession: PaywallSession // should only ever be modified in updateContent
    
    /// Stores context for loading state transitions; copied to new session when loading completes
    let presentationContext: PaywallPresentationContext
    
    var customWindow: UIWindow?
    
    private let loadStartTime: DispatchTime?
    private var displayTime: DispatchTime? = nil
    
    init(trigger: String, paywallSession: PaywallSession, fallbackReason: PaywallUnavailableReason?, contentView: AnyView, isLoading: Bool = false, presentationContext: PaywallPresentationContext) {
        self.trigger = trigger
        self.paywallSession = paywallSession
        self.fallbackReason = fallbackReason
        self.isLoading = isLoading
        self.presentationContext = presentationContext
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
    
    func updateContent(_ newContent: AnyView, newPaywallSession: PaywallSession?, fallbackReason: PaywallUnavailableReason?, isLoading: Bool) {
        if let newPaywallSession {
            self.paywallSession = newPaywallSession
        }
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
        let compareTime = displayTime ?? DispatchTime.now()
        if let loadStartTime {
            return dispatchTimeDifferenceInMS(from: loadStartTime, to: compareTime)
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
