//
//  HeliumPaywallView.swift
//  Helium
//

import SwiftUI

/// A SwiftUI view that displays Helium paywalls.
///
/// ## Example Usage
/// ```swift
/// // Minimal - uses default loading view
/// HeliumPaywallView(trigger: "onboarding") { reason in
///     Text("Paywall not shown: \(reason.rawValue)")
/// }
///
/// // With custom loading view
/// HeliumPaywallView(
///     trigger: "onboarding",
///     loadingView: { ProgressView() }
/// ) { reason in
///     Text("Paywall not shown: \(reason.rawValue)")
/// }
/// ```
@available(iOS 15.0, *)
public struct HeliumPaywallView<FallbackView: View>: View {
    
    /// Tracks which phase of loading we're in (config download vs entitlement check)
    private enum LoadingPhase {
        case waitingForConfig
        case checkingEntitlement
    }
    
    let trigger: String
    let loadingView: (() -> AnyView)?
    let fallbackView: (PaywallNotShownReason) -> FallbackView
    let eventHandlers: PaywallEventHandlers?
    let config: PaywallPresentationConfig
    
    @State private var state: HeliumPaywallViewState
    @State private var didConfigureContext = false
    @State private var loadingBudgetExpired = false
    @State private var loadingPhase: LoadingPhase = .waitingForConfig
    @State private var isEntitled: Bool? = nil
    
    /// Creates a new paywall view for the specified trigger with default loading view
    ///
    /// - Parameters:
    ///   - trigger: The trigger name to display a paywall for
    ///   - config: Additional configuration options
    ///   - eventHandlers: Optional event handlers for paywall lifecycle events
    ///   - fallbackView: View to show when paywall is unavailable or skipped due to targeting
    public init(
        trigger: String,
        config: PaywallPresentationConfig = PaywallPresentationConfig(),
        eventHandlers: PaywallEventHandlers? = nil,
        @ViewBuilder fallbackView: @escaping (PaywallNotShownReason) -> FallbackView
    ) {
        self.trigger = trigger
        self.loadingView = nil
        self.fallbackView = fallbackView
        self.eventHandlers = eventHandlers
        self.config = config
        
        self._state = State(initialValue: resolvePaywallState(for: trigger))
    }
    
    /// Creates a new paywall view for the specified trigger with custom loading view
    ///
    /// - Parameters:
    ///   - trigger: The trigger name to display a paywall for
    ///   - config: Additional configuration options
    ///   - eventHandlers: Optional event handlers for paywall lifecycle events
    ///   - loadingView: Custom view to show while paywall is loading
    ///   - fallbackView: View to show when paywall is unavailable or skipped due to targeting
    public init<LoadingView: View>(
        trigger: String,
        config: PaywallPresentationConfig = PaywallPresentationConfig(),
        eventHandlers: PaywallEventHandlers? = nil,
        @ViewBuilder loadingView: @escaping () -> LoadingView,
        @ViewBuilder fallbackView: @escaping (PaywallNotShownReason) -> FallbackView
    ) {
        self.trigger = trigger
        self.loadingView = { AnyView(loadingView()) }
        self.fallbackView = fallbackView
        self.eventHandlers = eventHandlers
        self.config = config
        
        self._state = State(initialValue: resolvePaywallState(for: trigger))
    }
    
    public var body: some View {
        Group {
            switch state {
            case .loading:
                resolvedLoadingView
            case .ready(let paywallViewAndSession):
                paywallViewAndSession.view
            case .fallback(let reason):
                fallbackView(reason)
                    .onAppear {
                        onPaywallUnavailable(reason: reason)
                    }
            }
        }
        .onAppear {
            configureContextIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("HeliumConfigDownloadComplete"))) { _ in
            if case .loading = state, !loadingBudgetExpired {
                Task {
                    await resolveStateAfterConfigReady()
                }
            }
        }
        .task(id: state) {
            // Only start timeout if currently in loading state
            guard case .loading = state else { return }
            
            let loadingBudget = Helium.config.defaultLoadingBudget
            
            try? await Task.sleep(nanoseconds: UInt64(loadingBudget * 1_000_000_000))
            
            // After timeout, re-resolve state with whatever info we have
            loadingBudgetExpired = true
            state = resolvePaywallState(for: trigger, isEntitled: isEntitled, allowLoadingState: false)
        }
    }
    
    @ViewBuilder
    private var resolvedLoadingView: some View {
        if let userLoadingView = loadingView {
            userLoadingView()
        } else if let configLoadingView = Helium.config.defaultLoadingView {
            configLoadingView
        } else {
            let backgroundConfig = HeliumFallbackViewManager.shared.getBackgroundConfigForTrigger(trigger)
            HeliumPaywallPresenter.shared.createDefaultLoadingView(backgroundConfig: backgroundConfig)
        }
    }
    
    private func configureContextIfNeeded() {
        guard !didConfigureContext else { return }
        
        HeliumPaywallDelegateWrapper.shared.configurePresentationContext(
            paywallPresentationConfig: config,
            eventService: eventHandlers,
            onEntitledHandler: nil,
            onPaywallNotShown: { _ in }
        )
        
        didConfigureContext = true
    }
    
    /// Called after config download completes to check entitlement and resolve final state
    private func resolveStateAfterConfigReady() async {
        let dontShowIfAlreadyEntitled = HeliumPaywallDelegateWrapper.shared.paywallPresentationConfig?.dontShowIfAlreadyEntitled ?? true
        
        // Check entitlement if needed
        if dontShowIfAlreadyEntitled {
            loadingPhase = .checkingEntitlement
            isEntitled = await Helium.shared.hasEntitlementForPaywall(trigger: trigger)
        }
        
        // Now resolve with full info
        state = resolvePaywallState(for: trigger, isEntitled: isEntitled, allowLoadingState: !loadingBudgetExpired)
    }
    
    private func onPaywallUnavailable(reason: PaywallNotShownReason) {
        switch reason {
        case .alreadyEntitled:
            // nothing for now
            break
        case .targetingHoldout:
            Helium.shared.handlePaywallSkip(trigger: trigger)
        case .error(unavailableReason: let unavailableReason):
            HeliumPaywallDelegateWrapper.shared.fireEvent(
                PaywallOpenFailedEvent(
                    triggerName: trigger,
                    paywallName: "",
                    error: "Paywall failed to show in embedded view.",
                    paywallUnavailableReason: unavailableReason,
                    loadingBudgetMS: loadingBudgetUInt64(trigger: trigger)
                ),
                paywallSession: nil
            )
        }
    }
}

/// Represents the current state of a paywall view
enum HeliumPaywallViewState: Equatable {
    /// Paywall is currently loading (config/bundles/products fetching)
    case loading
    /// Paywall is ready to display
    case ready(PaywallViewAndSession)
    /// Paywall is not shown for the given reason
    case fallback(PaywallNotShownReason)
    
    static func == (lhs: HeliumPaywallViewState, rhs: HeliumPaywallViewState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading):
            return true
        case (.ready, .ready):
            return true
        case (.fallback(let lReason), .fallback(let rReason)):
            return lReason == rReason
        default:
            return false
        }
    }
}

// MARK: - Helper Functions

/// Returns the current state of a paywall for the trigger
fileprivate func resolvePaywallState(
    for trigger: String,
    isEntitled: Bool? = nil,
    allowLoadingState: Bool = true
) -> HeliumPaywallViewState {
    if allowLoadingState && shouldShowLoadingState(for: trigger) {
        return .loading
    }
    
    let result = Helium.shared.upsellViewResultFor(trigger: trigger)
    
    if let viewAndSession = result.viewAndSession {
        return .ready(viewAndSession)
    }
    
    let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
    if paywallInfo?.shouldShow == false {
        return .fallback(.targetingHoldout)
    }
    
    // Check entitlement - if we need it but don't have it yet, keep loading
    let dontShowIfAlreadyEntitled = HeliumPaywallDelegateWrapper.shared.paywallPresentationConfig?.dontShowIfAlreadyEntitled ?? true
    if dontShowIfAlreadyEntitled {
        if isEntitled == nil && allowLoadingState {
            // Entitlement check hasn't completed yet, keep loading
            return .loading
        }
        if isEntitled == true {
            return .fallback(.alreadyEntitled)
        }
    }
    
    if let reason = result.fallbackReason {
        return .fallback(.error(unavailableReason: reason))
    }
    
    return .fallback(.error(unavailableReason: nil))
}

/// Determines if loading state should be shown by checking actual download status
fileprivate func shouldShowLoadingState(for trigger: String) -> Bool {
    // Check if loading is enabled for this trigger
    let useLoadingState = Helium.config.defaultLoadingBudget > 0
    if !useLoadingState {
        return false
    }
    
    // Check if downloads are in progress or pending
    let downloadStatus = HeliumFetchedConfigManager.shared.downloadStatus
    let heliumDownloadsIncoming = Helium.shared.isInitialized() &&
    (downloadStatus == .notDownloadedYet || downloadStatus == .inProgress)
    
    return heliumDownloadsIncoming
}

fileprivate func loadingBudgetUInt64(trigger: String) -> UInt64 {
    let loadingBudgetInSeconds = HeliumPaywallDelegateWrapper.shared.paywallPresentationConfig?.loadingBudget ?? Helium.config.defaultLoadingBudget
    return UInt64(loadingBudgetInSeconds * 1000)
}
