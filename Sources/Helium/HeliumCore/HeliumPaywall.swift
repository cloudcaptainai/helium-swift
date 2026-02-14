//
//  HeliumPaywall.swift
//  Helium
//

import SwiftUI

/// A SwiftUI view that displays Helium paywalls.
///
/// ## Example Usage
/// ```swift
/// // Minimal - uses default loading view
/// HeliumPaywall(trigger: "onboarding") { reason in
///     Text("Paywall not shown: \(reason.rawValue)")
/// }
///
/// // With custom loading view
/// HeliumPaywall(
///     trigger: "onboarding",
///     loadingView: { ProgressView() }
/// ) { reason in
///     Text("Paywall not shown: \(reason.rawValue)")
/// }
/// ```
public struct HeliumPaywall<PaywallNotShownView: View>: View {
    
    let trigger: String
    let loadingView: (() -> AnyView)?
    let paywallNotShownView: (PaywallNotShownReason) -> PaywallNotShownView
    let eventHandlers: PaywallEventHandlers?
    let config: PaywallPresentationConfig
    let presentationContext: PaywallPresentationContext
    
    @State private var state: HeliumPaywallViewState
    @State private var loadingBudgetExpired = false
    @State private var isEntitled: Bool? = nil
    @State private var loadingStartTime = DispatchTime.now()
    @State private var resolvedLoadTimeTakenMS: UInt64?
    
    /// Creates a new paywall view for the specified trigger with default loading view
    ///
    /// - Parameters:
    ///   - trigger: The trigger name to display a paywall for
    ///   - config: Additional configuration options
    ///   - eventHandlers: Optional event handlers for paywall lifecycle events
    ///   - whenPaywallNotShown: View to show when paywall is unavailable or skipped due to targeting
    public init(
        trigger: String,
        config: PaywallPresentationConfig = PaywallPresentationConfig(),
        eventHandlers: PaywallEventHandlers? = nil,
        @ViewBuilder whenPaywallNotShown: @escaping (PaywallNotShownReason) -> PaywallNotShownView
    ) {
        self.trigger = trigger
        self.loadingView = nil
        self.paywallNotShownView = whenPaywallNotShown
        self.eventHandlers = eventHandlers
        self.config = config
        self.presentationContext = PaywallPresentationContext(
            config: config,
            eventHandlers: eventHandlers,
            onEntitled: nil,
            onPaywallNotShown: nil
        )
        
        self._state = State(initialValue: resolvePaywallState(for: trigger, config: config, presentationContext: presentationContext))
    }
    
    /// Creates a new paywall view for the specified trigger with custom loading view
    ///
    /// - Parameters:
    ///   - trigger: The trigger name to display a paywall for
    ///   - config: Additional configuration options
    ///   - eventHandlers: Optional event handlers for paywall lifecycle events
    ///   - loadingView: Custom view to show while paywall is loading
    ///   - whenPaywallNotShown: View to show when paywall is unavailable or skipped due to targeting/already-entitled
    public init<LoadingView: View>(
        trigger: String,
        config: PaywallPresentationConfig = PaywallPresentationConfig(),
        eventHandlers: PaywallEventHandlers? = nil,
        @ViewBuilder loadingView: @escaping () -> LoadingView,
        @ViewBuilder whenPaywallNotShown: @escaping (PaywallNotShownReason) -> PaywallNotShownView
    ) {
        self.trigger = trigger
        self.loadingView = { AnyView(loadingView()) }
        self.paywallNotShownView = whenPaywallNotShown
        self.eventHandlers = eventHandlers
        self.config = config
        self.presentationContext = PaywallPresentationContext(
            config: config,
            eventHandlers: eventHandlers,
            onEntitled: nil,
            onPaywallNotShown: nil
        )
        
        self._state = State(initialValue: resolvePaywallState(for: trigger, config: config, presentationContext: presentationContext))
    }
    
    public var body: some View {
        Group {
            switch state {
            case .waitingForPaywallsDownload, .checkingEntitlement:
                resolvedLoadingView
            case .ready(let paywallViewAndSession):
                paywallViewAndSession.view
                    .environment(\.heliumLoadTimeTakenMS, resolvedLoadTimeTakenMS)
            case .noShow(let reason):
                paywallNotShownView(reason)
                    .onAppear {
                        onPaywallUnavailable(reason: reason)
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("HeliumConfigDownloadComplete"))) { _ in
            if case .waitingForPaywallsDownload = state, !loadingBudgetExpired {
                transitionState(allowLoadingState: !loadingBudgetExpired)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .heliumEmbeddedPaywallRenderFail)) { notification in
            guard case .ready(let paywallViewAndSession) = state,
                  let notificationSessionId = notification.userInfo?["sessionId"] as? String,
                  notificationSessionId == paywallViewAndSession.paywallSession.sessionId else {
                return
            }
            state = .noShow(.error(unavailableReason: .webviewRenderFail))
        }
        .task(id: state) {
            // Handle state-specific async work
            if case .checkingEntitlement = state {
                isEntitled = await Helium.entitlements.hasEntitlementForPaywall(trigger: trigger)
                // Check if task was cancelled (e.g. by loading budget timeout)
                guard !Task.isCancelled else { return }
                transitionState(allowLoadingState: !loadingBudgetExpired)
            }
        }
        .task {
            // Independent timeout covering all loading phases
            guard config.useLoadingState else {
                return
            }
            let loadingBudget = config.safeLoadingBudgetInSeconds
            do {
                try await Task.sleep(nanoseconds: UInt64(loadingBudget * 1_000_000_000))
            } catch {
                return
            }
            
            // After timeout, re-resolve state with whatever info we have
            loadingBudgetExpired = true
            if state.isLoading {
                transitionState(allowLoadingState: false)
            }
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
    
    private func transitionState(allowLoadingState: Bool) {
        let newState = resolvePaywallState(for: trigger, isEntitled: isEntitled, allowLoadingState: allowLoadingState, config: config, presentationContext: presentationContext)
        if state.isLoading && !newState.isLoading {
            resolvedLoadTimeTakenMS = dispatchTimeDifferenceInMS(from: loadingStartTime)
        }
        state = newState
    }
    
    private func onPaywallUnavailable(reason: PaywallNotShownReason) {
        switch reason {
        case .alreadyEntitled:
            HeliumPaywallDelegateWrapper.shared.fireEvent(
                PaywallSkippedEvent(triggerName: trigger, skipReason: .alreadyEntitled),
                paywallSession: nil
            )
        case .targetingHoldout:
            Helium.shared.handlePaywallSkip(trigger: trigger)
        case .error(unavailableReason: let unavailableReason):
            if unavailableReason == .webviewRenderFail {
                return
            }
            HeliumPaywallDelegateWrapper.shared.fireEvent(
                PaywallOpenFailedEvent(
                    triggerName: trigger,
                    paywallName: "",
                    error: "Paywall failed to show in embedded view.",
                    paywallUnavailableReason: unavailableReason,
                    loadtimeTakenMS: resolvedLoadTimeTakenMS,
                    loadingBudgetMS: config.loadingBudgetForAnalyticsMS
                ),
                paywallSession: nil,
                overridePresentationContext: presentationContext
            )
        }
    }
}

/// Represents the current state of a paywall view
enum HeliumPaywallViewState: Equatable {
    case waitingForPaywallsDownload
    case checkingEntitlement
    case ready(PaywallViewAndSession)
    case noShow(PaywallNotShownReason)
    
    var isLoading: Bool {
        switch self {
        case .waitingForPaywallsDownload, .checkingEntitlement: return true
        case .ready, .noShow: return false
        }
    }
    
    static func == (lhs: HeliumPaywallViewState, rhs: HeliumPaywallViewState) -> Bool {
        switch (lhs, rhs) {
        case (.waitingForPaywallsDownload, .waitingForPaywallsDownload):
            return true
        case (.checkingEntitlement, .checkingEntitlement):
            return true
        case (.ready, .ready):
            return true
        case (.noShow(let lReason), .noShow(let rReason)):
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
    allowLoadingState: Bool = true,
    config: PaywallPresentationConfig,
    presentationContext: PaywallPresentationContext
) -> HeliumPaywallViewState {
    if allowLoadingState && shouldShowLoadingState(for: trigger, config: config) {
        return .waitingForPaywallsDownload
    }
    
    let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
    if paywallInfo?.shouldShow == false {
        return .noShow(.targetingHoldout)
    }
    
    let dontShowIfAlreadyEntitled = config.dontShowIfAlreadyEntitled
    if dontShowIfAlreadyEntitled {
        if isEntitled == nil && allowLoadingState {
            return .checkingEntitlement
        }
        if isEntitled == true {
            return .noShow(.alreadyEntitled)
        }
    }
    
    let result = Helium.shared.upsellViewResultFor(trigger: trigger, presentationContext: presentationContext)
    
    if let viewAndSession = result.viewAndSession {
        return .ready(viewAndSession)
    }
    
    if let reason = result.fallbackReason {
        return .noShow(.error(unavailableReason: reason))
    }
    
    return .noShow(.error(unavailableReason: nil))
}

/// Determines if loading state should be shown by checking actual download status
private func shouldShowLoadingState(for trigger: String, config: PaywallPresentationConfig) -> Bool {
    if !config.useLoadingState {
        return false
    }
    
    // Check if downloads are in progress or pending
    let downloadStatus = HeliumFetchedConfigManager.shared.downloadStatus
    let heliumDownloadsIncoming = Helium.shared.isInitialized() &&
    (downloadStatus == .notDownloadedYet || downloadStatus == .inProgress)
    
    return heliumDownloadsIncoming
}

// MARK: - Load Time Environment Key

private struct HeliumLoadTimeTakenMSKey: EnvironmentKey {
    static let defaultValue: UInt64? = nil
}

extension EnvironmentValues {
    var heliumLoadTimeTakenMS: UInt64? {
        get { self[HeliumLoadTimeTakenMSKey.self] }
        set { self[HeliumLoadTimeTakenMSKey.self] = newValue }
    }
}
