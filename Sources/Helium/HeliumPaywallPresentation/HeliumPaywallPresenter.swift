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
    @HeliumAtomic private var sessionsWithEntitlement: Set<String> = []
    
    func isSecondTryPaywall(trigger: String) -> Bool {
        return paywallsDisplayed.contains {
            $0.trigger == trigger && $0.isSecondTry
        }
    }
    
    /// Mark a session as having achieved entitlement (purchase/restore succeeded).
    /// The onEntitled callback will be called when the paywall closes.
    func markSessionAsEntitled(sessionId: String) {
        _sessionsWithEntitlement.withValue { $0.insert(sessionId) }
    }
    
    private func paywallEntitlementsCheck(trigger: String, context: PaywallPresentationContext) async -> Bool {
        if context.config.dontShowIfAlreadyEntitled {
            let skipIt = await Helium.entitlements.hasEntitlementForPaywall(trigger: trigger)
            if skipIt == true {
                Task { @MainActor in
                    if let onEntitled = context.onEntitled {
                        onEntitled()
                    } else {
                        context.onPaywallNotShown?(.alreadyEntitled)
                    }
                }
                HeliumPaywallDelegateWrapper.shared.fireEvent(
                    PaywallSkippedEvent(triggerName: trigger, skipReason: .alreadyEntitled),
                    paywallSession: nil
                )
                return true
            }
        }
        return false
    }
    
    func skipPaywallIfNeeded(trigger: String, presentationContext: PaywallPresentationContext) -> Bool {
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        if paywallInfo?.shouldShow == false {
            handlePaywallSkip(trigger: trigger)
            presentationContext.onPaywallNotShown?(.targetingHoldout)
            return true
        }
        return false
    }
    
    func handlePaywallSkip(trigger: String) {
        // Fire allocation event even when paywall is skipped
        ExperimentAllocationTracker.shared.trackAllocationIfNeeded(
            trigger: trigger,
            isFallback: false,
            paywallSession: nil
        )
        
        HeliumPaywallDelegateWrapper.shared.fireEvent(
            PaywallSkippedEvent(triggerName: trigger),
            paywallSession: nil
        )
    }
    
    func presentUpsell(trigger: String, isSecondTry: Bool = false, presentationContext: PaywallPresentationContext) {
        Task { @MainActor in
            if await paywallEntitlementsCheck(trigger: trigger, context: presentationContext) {
                return
            }
            
            let upsellViewResult = upsellViewResultFor(trigger: trigger, presentationContext: presentationContext)
            guard let viewAndSession = upsellViewResult.viewAndSession else {
                HeliumPaywallDelegateWrapper.shared.fireEvent(
                    PaywallOpenFailedEvent(
                        triggerName: trigger,
                        paywallName: "",
                        error: "No paywall for trigger and no fallback available when present called.",
                        paywallUnavailableReason: upsellViewResult.fallbackReason,
                        loadingBudgetMS: presentationContext.config.loadingBudgetForAnalyticsMS,
                        secondTry: isSecondTry
                    ),
                    paywallSession: nil,
                    overridePresentationContext: presentationContext
                )
                return
            }
            let contentView = viewAndSession.view
            presentPaywall(trigger: trigger, paywallSession: viewAndSession.paywallSession, fallbackReason: upsellViewResult.fallbackReason, isSecondTry: isSecondTry, contentView: contentView, presentationContext: presentationContext)
        }
    }
    
    func presentUpsellWithLoadingBudget(trigger: String, presentationContext: PaywallPresentationContext) {
        let config = presentationContext.config
        HeliumLogger.log(.debug, category: .ui, "presentUpsellWithLoadingBudget called", metadata: ["trigger": trigger])
        if !paywallsDisplayed.isEmpty {
            // Only allow one paywall to be presented at a time. (Exception being second try paywalls.)
            // Note that this is a special "open fail" case -- session and presentationContext are intentionally not availalbe
            // for the event because we don't want to call `onPaywallNotShown` for this.
            HeliumLogger.log(.warn, category: .ui, "Paywall already being presented, skipping", metadata: ["trigger": trigger])
            HeliumPaywallDelegateWrapper.shared.fireEvent(
                PaywallOpenFailedEvent(
                    triggerName: trigger,
                    paywallName: Helium.shared.getPaywallInfo(trigger: trigger)?.paywallTemplateName ?? "unknown",
                    error: "A paywall is already being presented.",
                    paywallUnavailableReason: .alreadyPresented,
                    loadingBudgetMS: config.loadingBudgetForAnalyticsMS
                ),
                paywallSession: nil
            )
            return
        }
        
        Task { @MainActor in
            // Check if paywall is ready
            if Helium.shared.paywallsLoaded() {
                presentUpsell(trigger: trigger, presentationContext: presentationContext)
                return
            }
            
            let loadingBudget = config.safeLoadingBudgetInSeconds
            let useLoading = config.useLoadingState
            let customLoadingView = Helium.config.defaultLoadingView
            
            let downloadStatus = Helium.shared.getDownloadStatus()
            let heliumDownloadsIncoming = Helium.shared.isInitialized() && (downloadStatus == .notDownloadedYet || downloadStatus == .inProgress)
            // If loading state disabled for this trigger, show fallback immediately
            if !useLoading || !heliumDownloadsIncoming {
                presentUpsell(trigger: trigger, presentationContext: presentationContext)
                return
            }
            
            // Get background config from fallback bundle if available
            let fallbackBgConfig = HeliumFallbackViewManager.shared.getBackgroundConfigForTrigger(trigger)
            
            // Note that this paywall session will get replaced once paywall is succesfully loaded.
            let paywallSession = PaywallSession(trigger: trigger, paywallInfo: nil, fallbackType: .notFallback, presentationContext: presentationContext)
            
            // Show loading state with trigger-specific or default loading view
            let loadingView = customLoadingView ?? createDefaultLoadingView(backgroundConfig: fallbackBgConfig)
            presentPaywall(trigger: trigger, paywallSession: paywallSession, fallbackReason: nil, contentView: loadingView, isLoading: true, presentationContext: presentationContext)
            
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
        
        // Get context from the loading paywall's stored context
        let context = loadingPaywall.presentationContext
        
        if skipPaywallIfNeeded(trigger: trigger, presentationContext: context) {
            hideUpsell()
            return
        }
        
        if await paywallEntitlementsCheck(trigger: trigger, context: context) {
            hideUpsell()
            return
        }
        
        let upsellViewResult = upsellViewResultFor(trigger: trigger, presentationContext: context)
        guard let viewAndSession = upsellViewResult.viewAndSession else {
            let loadTimeTakenMS = loadingPaywall.loadTimeTakenMS
            let loadingBudgetMS = context.config.loadingBudgetForAnalyticsMS
            hideUpsell {
                HeliumPaywallDelegateWrapper.shared.fireEvent(
                    PaywallOpenFailedEvent(
                        triggerName: trigger,
                        paywallName: "",
                        error: "No paywall for trigger and no fallback available after load complete.",
                        paywallUnavailableReason: upsellViewResult.fallbackReason,
                        loadTimeTakenMS: loadTimeTakenMS,
                        loadingBudgetMS: loadingBudgetMS,
                        newWindowCreated: loadingPaywall.customWindow != nil
                    ),
                    paywallSession: loadingPaywall.paywallSession
                )
            }
            return
        }
        loadingPaywall.updateContent(viewAndSession.view, newPaywallSession: viewAndSession.paywallSession, fallbackReason: upsellViewResult.fallbackReason, isLoading: false)
        
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
    
    func createDefaultLoadingView(backgroundConfig: BackgroundConfig? = nil) -> AnyView {
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
    private func presentPaywall(trigger: String, paywallSession: PaywallSession, fallbackReason: PaywallUnavailableReason?, isSecondTry: Bool = false, contentView: AnyView, isLoading: Bool = false, presentationContext: PaywallPresentationContext) {
#if DEBUG
        HeliumPaywallDiagnosticView.dismissIfPresented()
#endif
        HeliumLogger.log(.debug, category: .ui, "Presenting paywall", metadata: [
            "trigger": trigger,
            "isLoading": String(isLoading),
            "isSecondTry": String(isSecondTry),
            "isFallback": String(fallbackReason != nil)
        ])
        let modalVC = HeliumViewController(trigger: trigger, paywallSession: paywallSession, fallbackReason: fallbackReason, isSecondTry: isSecondTry, contentView: contentView, isLoading: isLoading, presentationContext: presentationContext)
        modalVC.modalPresentationStyle = .fullScreen
        
        var presenter = presentationContext.config.presentFromViewController
        if presenter == nil, let windowScene = UIWindowHelper.findActiveWindow()?.windowScene {
            let newWindow = UIWindow(windowScene: windowScene)
            let containerVC = UIViewController()
            newWindow.rootViewController = containerVC
            newWindow.windowLevel = .alert + 1
            newWindow.makeKeyAndVisible()
            presenter = containerVC
            
            modalVC.customWindow = newWindow
        }
        // Try this as backup but if new window failed, this likely will too.
        if presenter == nil {
            presenter = UIWindowHelper.findTopMostViewController()
        }
        
        guard let presenter else {
            // Failed to find a view controller to present on - this should never happen
            HeliumLogger.log(.error, category: .ui, "No window scene found to present paywall", metadata: ["trigger": trigger])
            HeliumPaywallDelegateWrapper.shared.fireEvent(
                PaywallOpenFailedEvent(
                    triggerName: trigger,
                    paywallName: Helium.shared.getPaywallInfo(trigger: trigger)?.paywallTemplateName ?? "unknown",
                    error: "No window scene found",
                    paywallUnavailableReason: .noRootController,
                    loadingBudgetMS: presentationContext.config.loadingBudgetForAnalyticsMS
                ),
                paywallSession: paywallSession
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
        guard !paywallsDisplayed.isEmpty else {
            HeliumLogger.log(.debug, category: .ui, "Attempted to hide paywall but no paywall to hide")
            return false
        }
        Task { @MainActor in
            guard let currentPaywall = paywallsDisplayed.popLast() else {
                return
            }
            HeliumLogger.log(.trace, category: .ui, "Hiding paywall", metadata: ["trigger": currentPaywall.trigger])
            // Use presentingViewController to ensure cascading dismiss (e.g., if paywall is presenting an alert)
            if let presenter = currentPaywall.presentingViewController {
                presenter.dismiss(animated: animated) { [weak self] in
                    if let overrideCloseEvent {
                        overrideCloseEvent()
                    } else {
                        self?.dispatchCloseEvent(paywallVC: currentPaywall)
                    }
                }
            } else {
                // Not expected to occur, but try indirect dismissal as backup
                currentPaywall.dismiss(animated: animated) { [weak self] in
                    if let overrideCloseEvent {
                        overrideCloseEvent()
                    } else {
                        self?.dispatchCloseEvent(paywallVC: currentPaywall)
                    }
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
        
        Task { @MainActor in
            let paywallsToRemove = paywallsDisplayed
            paywallsDisplayed.removeAll()
            let group = DispatchGroup()
            
            for (index, paywall) in paywallsToRemove.reversed().enumerated() {
                group.enter()
                // Only animate the first (topmost) paywall
                let shouldAnimate = index == 0
                // Use presentingViewController to ensure cascading dismiss (e.g., if paywall is presenting an alert)
                if let presenter = paywall.presentingViewController {
                    presenter.dismiss(animated: shouldAnimate) {
                        group.leave()
                    }
                } else {
                    // Not expected to occur, but try indirect dismissal as backup
                    paywall.dismiss(animated: shouldAnimate) {
                        group.leave()
                    }
                }
            }
            
            group.notify(queue: .main) { [weak self] in
                // Fire close events topmost to bottom
                self?.dispatchCloseForAll(paywallVCs: paywallsToRemove.reversed())
                onComplete?()
            }
        }
    }
    
    func cleanUpPaywall(heliumViewController: HeliumViewController) {
        dispatchCloseForAll(paywallVCs: paywallsDisplayed.filter { $0 === heliumViewController })
        paywallsDisplayed.removeAll { $0 === heliumViewController }
        
        // Probably not necessary but explicitly clear to be safe
        heliumViewController.customWindow?.windowScene = nil
        heliumViewController.customWindow = nil
    }
    
    private func dispatchOpenEvent(paywallVC: HeliumViewController) {
        dispatchOpenOrCloseEvent(openEvent: true, paywallVC: paywallVC)
    }
    
    private func dispatchCloseEvent(paywallVC: HeliumViewController) {
        dispatchOpenOrCloseEvent(openEvent: false, paywallVC: paywallVC)
        
        // Call onEntitled if this session had a successful purchase/restore
        let sessionId = paywallVC.paywallSession.sessionId
        var wasEntitled = false
        _sessionsWithEntitlement.withValue { wasEntitled = $0.remove(sessionId) != nil }
        if wasEntitled {
            Task { @MainActor in
                paywallVC.presentationContext.onEntitled?()
            }
        }
    }
    
    private func dispatchOpenOrCloseEvent(openEvent: Bool, paywallVC: HeliumViewController) {
        if paywallVC.isLoading {
            return // don't fire an event in this case
        }
        
        let trigger = paywallVC.trigger
        let paywallInfo = paywallVC.paywallSession.paywallInfoWithBackups
        let templateName = paywallInfo?.paywallTemplateName ?? ""
        
        let event: HeliumEvent
        if openEvent {
            ExperimentAllocationTracker.shared.trackAllocationIfNeeded(
                trigger: paywallVC.trigger,
                isFallback: paywallVC.isFallback,
                paywallSession: paywallVC.paywallSession
            )
            
            let loadTimeTakenMS = paywallVC.loadTimeTakenMS
            let loadingBudgetMS = paywallVC.presentationContext.config.loadingBudgetForAnalyticsMS
            
            event = PaywallOpenEvent(
                triggerName: trigger,
                paywallName: templateName,
                viewType: .presented,
                loadTimeTakenMS: loadTimeTakenMS,
                loadingBudgetMS: loadingBudgetMS,
                paywallUnavailableReason: paywallVC.fallbackReason,
                newWindowCreated: paywallVC.customWindow != nil
            )
        } else {
            event = PaywallCloseEvent(
                triggerName: trigger,
                paywallName: templateName,
                secondTry: paywallVC.isSecondTry
            )
        }
        HeliumPaywallDelegateWrapper.shared.fireEvent(event, paywallSession: paywallVC.paywallSession)
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

extension HeliumPaywallPresenter {
    func upsellViewResultFor(trigger: String, presentationContext: PaywallPresentationContext) -> PaywallViewResult {
        HeliumLogger.log(.debug, category: .ui, "upsellViewResultFor called", metadata: ["trigger": trigger])
        if !Helium.shared.isInitialized() {
            // Note - no fallback paywall here since fallbacks not initialized yet either
            HeliumLogger.log(.warn, category: .core, "Helium not initialized when presenting paywall")
            return PaywallViewResult(viewAndSession: nil, fallbackReason: .notInitialized)
        }
        
        let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
        if Helium.shared.paywallsLoaded() {
            guard let templatePaywallInfo = paywallInfo else {
                return fallbackViewFor(trigger: trigger, paywallInfo: nil, fallbackReason: .triggerHasNoPaywall, presentationContext: presentationContext)
            }
            if templatePaywallInfo.forceShowFallback == true {
                return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: .forceShowFallback, presentationContext: presentationContext)
            }
            
            if let bundleSkip = HeliumFetchedConfigManager.shared.triggersWithSkippedBundleAndReason.first(where: { $0.trigger == trigger }) {
                return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: bundleSkip.reason, presentationContext: presentationContext)
            }
            
            if !templatePaywallInfo.hasProducts {
                return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: .noProductsIOS, presentationContext: presentationContext)
            }
            
            let hasPaddleProducts = !(templatePaywallInfo.productsOfferedPaddle ?? []).isEmpty
            let hasStripeProducts = !(templatePaywallInfo.productsOfferedStripe ?? []).isEmpty
            let hasAppToWebProducts = hasPaddleProducts || hasStripeProducts
            if hasAppToWebProducts && !HeliumIdentityManager.shared.hasCustomUserId() {
                return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: .webCheckoutNoCustomUserId, presentationContext: presentationContext)
            }
            let processors = Helium.config.webCheckoutProcessors
            let paddleUsable = hasPaddleProducts && processors.contains(.paddle)
            let stripeUsable = hasStripeProducts && processors.contains(.stripe)
            if hasAppToWebProducts && !(paddleUsable || stripeUsable) {
                return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: .webCheckoutNotEnabled, presentationContext: presentationContext)
            }
            
            do {
                guard let filePath = templatePaywallInfo.localBundlePath else {
                    HeliumLogger.log(.warn, category: .ui, "No local bundle path for trigger", metadata: ["trigger": trigger])
                    return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: .couldNotFindBundleUrl, presentationContext: presentationContext)
                }
                let backupFilePath = HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger)?.localBundlePath
                
                let paywallSession = PaywallSession(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackType: .notFallback, presentationContext: presentationContext)
                
                let paywallView = try AnyView(DynamicBaseTemplateView(
                    paywallSession: paywallSession,
                    fallbackReason: nil,
                    filePath: filePath,
                    backupFilePath: backupFilePath,
                    resolvedConfig: HeliumFetchedConfigManager.shared.getResolvedConfigJSONForTrigger(trigger)
                ))
                HeliumLogger.log(.debug, category: .ui, "Created paywall view for trigger", metadata: ["trigger": trigger])
                return PaywallViewResult(viewAndSession: PaywallViewAndSession(view: paywallView, paywallSession: paywallSession), fallbackReason: nil)
            } catch {
                HeliumLogger.log(.error, category: .ui, "Failed to create Helium view wrapper: \(error). Falling back.", metadata: ["trigger": trigger])
                return fallbackViewFor(trigger: trigger, paywallInfo: templatePaywallInfo, fallbackReason: .invalidResolvedConfig, presentationContext: presentationContext)
            }
        } else {
            let fallbackReason: PaywallUnavailableReason
            switch HeliumFetchedConfigManager.shared.downloadStatus {
            case .notDownloadedYet:
                fallbackReason = .paywallsNotDownloaded
            case .inProgress:
                switch HeliumFetchedConfigManager.shared.downloadStep {
                case .config:
                    fallbackReason = .configFetchInProgress
                case .bundles:
                    fallbackReason = .bundlesFetchInProgress
                case .products:
                    fallbackReason = .productsFetchInProgress
                }
            case .downloadSuccess:
                // Not reachable with current code paths, but include so all switch cases are accounted for.
                fallbackReason = .triggerHasNoPaywall
            case .downloadFailure:
                fallbackReason = .paywallsDownloadFail
            }
            return fallbackViewFor(trigger: trigger, paywallInfo: paywallInfo, fallbackReason: fallbackReason, presentationContext: presentationContext)
        }
    }
    
    private func fallbackViewFor(trigger: String, paywallInfo: HeliumPaywallInfo?, fallbackReason: PaywallUnavailableReason, presentationContext: PaywallPresentationContext) -> PaywallViewResult {
        
        // Do not show fallback for a paywall preview
        if trigger == HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER {
            return PaywallViewResult(viewAndSession: nil, fallbackReason: fallbackReason)
        }
        
        // Check existing fallback mechanisms
        if let fallbackPaywallInfo = HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger),
           let filePath = fallbackPaywallInfo.localBundlePath {
            do {
                let fallbackBundlePaywallSession = PaywallSession(trigger: trigger, paywallInfo: fallbackPaywallInfo, fallbackType: .fallbackBundle, presentationContext: presentationContext)
                let fallbackBundleView = try AnyView(
                    DynamicBaseTemplateView(
                        paywallSession: fallbackBundlePaywallSession,
                        fallbackReason: fallbackReason,
                        filePath: filePath,
                        backupFilePath: nil,
                        resolvedConfig: HeliumFallbackViewManager.shared.getResolvedConfigJSONForTrigger(trigger)
                    )
                )
                return PaywallViewResult(viewAndSession: PaywallViewAndSession(view: fallbackBundleView, paywallSession: fallbackBundlePaywallSession), fallbackReason: fallbackReason)
            } catch {
                HeliumLogger.log(.warn, category: .fallback, "Failed to create fallback view", metadata: ["trigger": trigger, "error": "\(error)"])
            }
        }
        return PaywallViewResult(viewAndSession: nil, fallbackReason: fallbackReason)
    }
}
