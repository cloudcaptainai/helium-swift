import Foundation
import SwiftUI
import UIKit

class HeliumPaywallPresenter {
    static let shared = HeliumPaywallPresenter()
    
    private let configDownloadEventName = NSNotification.Name("HeliumConfigDownloadComplete")
    private let slideInTransitioningDelegate = SlideInTransitioningDelegate()
    
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }
    
    private var paywallsDisplayed: [HeliumViewController] = []
    
    func isSecondTryPaywall(trigger: String) -> Bool {
        return paywallsDisplayed.contains {
            $0.isSecondTry
        }
    }
    
    private func paywallEntitlementsCheck(trigger: String) async -> Bool {
        if HeliumPaywallDelegateWrapper.shared.dontShowIfAlreadyEntitled {
            let skipIt = await Helium.shared.hasEntitlementForPaywall(trigger: trigger)
            if skipIt == true {
                print("[Helium] Did not show paywall, user already has entitlement.")
                return true
            }
        }
        return false
    }
    
    func presentUpsell(trigger: String, isSecondTry: Bool = false, from viewController: UIViewController? = nil) {
        Task { @MainActor in
            if await paywallEntitlementsCheck(trigger: trigger) {
                return
            }
            
            let upsellViewResult = Helium.shared.upsellViewResultFor(trigger: trigger)
            guard let contentView = upsellViewResult.view else {
                HeliumPaywallDelegateWrapper.shared.fireEvent(
                    PaywallOpenFailedEvent(
                        triggerName: trigger,
                        paywallName: upsellViewResult.templateName ?? "unknown",
                        error: "No paywall for trigger and no fallback available when present called.",
                        paywallUnavailableReason: upsellViewResult.fallbackReason
                    )
                )
                return
            }
            presentPaywall(trigger: trigger, fallbackReason: upsellViewResult.fallbackReason, isSecondTry: isSecondTry, contentView: contentView, from: viewController)
        }
    }
    
    func presentUpsellWithLoadingBudget(trigger: String, from viewController: UIViewController? = nil) {
        if !paywallsDisplayed.isEmpty {
            // Only allow one paywall to be presented at a time. (Exception being second try paywalls.)
            print("[Helium] A paywall is already being presented.")
            HeliumPaywallDelegateWrapper.shared.fireEvent(
                PaywallOpenFailedEvent(
                    triggerName: trigger,
                    paywallName: Helium.shared.getPaywallInfo(trigger: trigger)?.paywallTemplateName ?? "unknown",
                    error: "A paywall is already being presented.",
                    paywallUnavailableReason: "alreadyPresented"
                )
            )
            return
        }
        
        Task { @MainActor in
            // Check if paywall is ready
            if Helium.shared.paywallsLoaded() {
                presentUpsell(trigger: trigger, from: viewController)
                return
            }
            
            // Get fallback configuration
            let fallbackConfig = Helium.shared.fallbackConfig
            
            // Get trigger-specific loading configuration
            let useLoading = fallbackConfig?.useLoadingState(for: trigger) ?? false
            let loadingBudget = fallbackConfig?.loadingBudget(for: trigger) ?? 0
            let triggerLoadingView = fallbackConfig?.loadingView(for: trigger)
            
            // If loading state disabled for this trigger, show fallback immediately
            if !useLoading || Helium.shared.getDownloadStatus() != .inProgress {
                presentUpsell(trigger: trigger, from: viewController)
                return
            }
            
            // Get background config from fallback bundle if available
            let fallbackBgConfig = HeliumFallbackViewManager.shared.getBackgroundConfigForTrigger(trigger)
            
            // Show loading state with trigger-specific or default loading view
            let loadingView = triggerLoadingView ?? createDefaultLoadingView(backgroundConfig: fallbackBgConfig)
            presentPaywall(trigger: trigger, fallbackReason: nil, contentView: loadingView, from: viewController, isLoading: true)
            
            // Schedule timeout with trigger-specific budget
            Task {
                try? await Task.sleep(nanoseconds: UInt64(loadingBudget * 1_000_000_000))
                await updateLoadingPaywall(trigger: trigger)
                NotificationCenter.default.removeObserver(self, name: configDownloadEventName, object: nil)
            }
            
            // Also listen for download completion
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleDownloadComplete(_:)),
                name: configDownloadEventName,
                object: nil
            )
        }
    }
    
    @MainActor
    private func updateLoadingPaywall(trigger: String) async {
        guard let loadingPaywall = paywallsDisplayed.first(where: { $0.trigger == trigger && $0.isLoading }) else {
            return
        }
        
        if Helium.shared.skipPaywallIfNeeded(trigger: trigger) {
            hideUpsell()
            return
        }
        
        if await paywallEntitlementsCheck(trigger: trigger) {
            return
        }
        
        let upsellViewResult = Helium.shared.upsellViewResultFor(trigger: trigger)
        guard let upsellView = upsellViewResult.view else {
            hideUpsell {
                HeliumPaywallDelegateWrapper.shared.fireEvent(
                    PaywallOpenFailedEvent(
                        triggerName: trigger,
                        paywallName: upsellViewResult.templateName ?? "unknown",
                        error: "No paywall for trigger and no fallback available after load complete.",
                        paywallUnavailableReason: upsellViewResult.fallbackReason
                    )
                )
            }
            return
        }
        loadingPaywall.updateContent(upsellView, fallbackReason: upsellViewResult.fallbackReason, isLoading: false)
        
        // Dispatch the official open event
        dispatchOpenEvent(paywallVC: loadingPaywall)
    }
    
    @objc private func handleDownloadComplete(_ notification: Notification) {
        Task { @MainActor in
            // Update any loading paywalls
            for paywall in paywallsDisplayed where paywall.isLoading {
                await updateLoadingPaywall(trigger: paywall.trigger)
            }
        }
        NotificationCenter.default.removeObserver(self, name: configDownloadEventName, object: nil)
    }
    
    private func createDefaultLoadingView(backgroundConfig: BackgroundConfig? = nil) -> AnyView {
        // Use shimmer view to match the app open PR approach
        let defaultShimmerConfig = JSON([
            "layout": [
                "type": "vStack",
                "spacing": 20,
                "content": [
                    [
                        "type": "element",
                        "content": [
                            "elementType": "rectangle",
                            "width": 80,
                            "height": 15,
                            "cornerRadius": 8
                        ]
                    ],
                    [
                        "type": "element",
                        "content": [
                            "elementType": "rectangle",
                            "width": 90,
                            "height": 40,
                            "cornerRadius": 12
                        ]
                    ],
                    [
                        "type": "hStack",
                        "spacing": 10,
                        "content": [
                            [
                                "type": "element",
                                "content": [
                                    "elementType": "rectangle",
                                    "width": 40,
                                    "height": 60,
                                    "cornerRadius": 8
                                ]
                            ],
                            [
                                "type": "element",
                                "content": [
                                    "elementType": "rectangle",
                                    "width": 40,
                                    "height": 60,
                                    "cornerRadius": 8
                                ]
                            ]
                        ]
                    ],
                    [
                        "type": "element",
                        "content": [
                            "elementType": "rectangle",
                            "width": 80,
                            "height": 15,
                            "cornerRadius": 8
                        ]
                    ]
                ]
            ]
        ])
        
        return AnyView(
            ZStack {
                // Use provided background config or default to white
                if let bgConfig = backgroundConfig {
                    bgConfig.makeBackgroundView()
                } else {
                    Color.white
                }
                
                VStack {
                    Spacer()
                    EmptyView()
                        .shimmer(config: defaultShimmerConfig)
                    Spacer()
                }
            }
            .edgesIgnoringSafeArea(.all)
        )
    }
    
    @MainActor
    private func presentPaywall(trigger: String, fallbackReason: String?, isSecondTry: Bool = false, contentView: AnyView, from viewController: UIViewController? = nil, isLoading: Bool = false) {
        let modalVC = HeliumViewController(trigger: trigger, fallbackReason: fallbackReason, isSecondTry: isSecondTry, contentView: contentView, isLoading: isLoading)
        modalVC.modalPresentationStyle = .fullScreen
        
        guard let presenter = viewController ?? UIWindowHelper.findTopMostViewController() else {
            // Failed to find a view controller to present on - dispatch open failed event
            HeliumPaywallDelegateWrapper.shared.fireEvent(
                PaywallOpenFailedEvent(
                    triggerName: trigger,
                    paywallName: Helium.shared.getPaywallInfo(trigger: trigger)?.paywallTemplateName ?? "unknown",
                    error: "No root view controller found",
                    paywallUnavailableReason: "noRootController"
                )
            )
            return
        }
        
        let paywallInfo = fallbackReason == nil ? HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger) : HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger)
        switch paywallInfo?.presentationStyle {
        case .slideUp:
            break
        case .slideLeft:
            modalVC.modalPresentationStyle = .custom
            modalVC.transitioningDelegate = slideInTransitioningDelegate
        case .crossDissolve:
            modalVC.modalTransitionStyle = .crossDissolve
        case .flipHorizontal:
            modalVC.modalTransitionStyle = .flipHorizontal
        default:
            break
        }
        presenter.present(modalVC, animated: true)
        
        paywallsDisplayed.append(modalVC)

        dispatchOpenEvent(paywallVC: modalVC)
    }
    
    @discardableResult
    func hideUpsell(animated: Bool = true, overrideCloseEvent: (() -> Void)? = nil) -> Bool {
        guard let currentPaywall = paywallsDisplayed.popLast(),
              currentPaywall.presentingViewController != nil else {
            return false
        }
        Task { @MainActor in
            currentPaywall.dismiss(animated: animated) { [weak self] in
                if let overrideCloseEvent {
                    overrideCloseEvent()
                } else {
                    self?.dispatchCloseEvent(paywallVC: currentPaywall)
                }
            }
        }
        return true
    }
    
    func hideAllUpsells(onComplete: (() -> Void)? = nil) {
        if paywallsDisplayed.isEmpty {
            onComplete?()
            return
        }
        let paywallsRemoved = paywallsDisplayed
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
    
    private func dispatchOpenEvent(paywallVC: HeliumViewController) {
        dispatchOpenOrCloseEvent(openEvent: true, paywallVC: paywallVC)
        
        // Fire user allocation event if this is the first time showing this trigger
        ExperimentAllocationTracker.shared.trackAllocationIfNeeded(
            trigger: paywallVC.trigger,
            isFallback: paywallVC.isFallback
        )
    }
    
    private func dispatchCloseEvent(paywallVC: HeliumViewController) {
        dispatchOpenOrCloseEvent(openEvent: false, paywallVC: paywallVC)
    }
    
    private func dispatchOpenOrCloseEvent(openEvent: Bool, paywallVC: HeliumViewController) {
        if paywallVC.isLoading {
            return // don't fire an event in this case
        }
        let trigger = paywallVC.trigger
        let isFallback = paywallVC.isFallback
        let paywallInfo = !isFallback ? HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger) : HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger)
        let templateBackupName = isFallback ? HELIUM_FALLBACK_PAYWALL_NAME : "unknown"
        let templateName = paywallInfo?.paywallTemplateName ?? templateBackupName
        
        let event: HeliumEvent
        if openEvent {
            let loadTimeTakenMS = paywallVC.loadTimeTakenMS
            let loadingBudget = Helium.shared.fallbackConfig?.loadingBudget(for: trigger)
            var loadingBudgetMS: UInt64? = nil
            if loadTimeTakenMS != nil, let loadingBudget {
                loadingBudgetMS = UInt64(loadingBudget * 1000)
            }
            event = PaywallOpenEvent(
                triggerName: trigger,
                paywallName: templateName,
                viewType: .presented,
                loadTimeTakenMS: loadTimeTakenMS,
                loadingBudgetMS: loadingBudgetMS,
                paywallUnavailableReason: paywallVC.fallbackReason
            )
        } else {
            event = PaywallCloseEvent(
                triggerName: trigger,
                paywallName: templateName
            )
        }
        HeliumPaywallDelegateWrapper.shared.fireEvent(event)
    }
    
    private func dispatchCloseForAll(paywallVCs: [HeliumViewController]) {
        for paywallDisplay in paywallVCs {
            dispatchCloseEvent(paywallVC: paywallDisplay)
        }
    }
    
    @objc private func appWillTerminate() {
        // attempt to dispatch paywallClose analytics event even if user rage quits
        dispatchCloseForAll(paywallVCs: paywallsDisplayed)
        paywallsDisplayed.removeAll()
    }

}

// MARK: - Slide-in Animation Classes

/// Transitioning delegate that manages the slide-in animation from right
class SlideInTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {

    func animationController(forPresented presented: UIViewController,
                              presenting: UIViewController,
                              source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return SlideInPresentationAnimator()
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return SlideInDismissalAnimator()
    }
}

/// Animator for presenting the view controller with a slide-in from right animation
class SlideInPresentationAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let animationDuration: TimeInterval = 0.24

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return animationDuration
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard let toViewController = transitionContext.viewController(forKey: .to),
              let toView = toViewController.view else {
            transitionContext.completeTransition(false)
            return
        }

        let containerView = transitionContext.containerView
        let finalFrame = transitionContext.finalFrame(for: toViewController)

        // Position the view off-screen to the right
        toView.frame = finalFrame
        toView.frame.origin.x = containerView.frame.width

        // Add shadow for depth effect
        toView.layer.shadowColor = UIColor.black.cgColor
        toView.layer.shadowOpacity = 0.2
        toView.layer.shadowOffset = CGSize(width: -5, height: 0)
        toView.layer.shadowRadius = 10

        containerView.addSubview(toView)

        // Animate sliding in from the right
        UIView.animate(
            withDuration: animationDuration,
            delay: 0,
            options: [.curveEaseOut],
            animations: {
                toView.frame = finalFrame
            },
            completion: { finished in
                transitionContext.completeTransition(finished)
            }
        )
    }
}

/// Animator for dismissing the view controller with a slide-out to right animation
class SlideInDismissalAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let animationDuration: TimeInterval = 0.20

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return animationDuration
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard let fromViewController = transitionContext.viewController(forKey: .from),
              let fromView = fromViewController.view else {
            transitionContext.completeTransition(false)
            return
        }

        let containerView = transitionContext.containerView

        // Animate sliding out to the right
        UIView.animate(
            withDuration: animationDuration,
            delay: 0,
            options: [.curveEaseOut],
            animations: {
                fromView.frame.origin.x = containerView.frame.width
            },
            completion: { finished in
                fromView.removeFromSuperview()
                transitionContext.completeTransition(finished)
            }
        )
    }
}
