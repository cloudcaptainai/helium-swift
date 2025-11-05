//
//  HeliumPaywallView.swift
//  Helium
//
//  SwiftUI view that exposes paywall states (loading, ready, unavailable)
//

import Foundation
import SwiftUI

/// A SwiftUI view that displays Helium paywalls.
///
/// ## Example Usage
/// ```swift
/// // Minimal - uses default loading view
/// HeliumPaywallView(trigger: "onboarding") { reason in
///     Text("Paywall unavailable: \(reason.rawValue)")
/// }
///
/// // With custom loading view
/// HeliumPaywallView(
///     trigger: "onboarding",
///     loadingView: { ProgressView() }
/// ) { reason in
///     Text("Paywall unavailable: \(reason.rawValue)")
/// }
/// ```
@available(iOS 15.0, *)
public struct HeliumPaywallView<FallbackView: View>: View {
    let trigger: String
    let loadingView: (() -> AnyView)?
    let fallbackView: (PaywallUnavailableReason) -> FallbackView
    let eventHandlers: PaywallEventHandlers?
    let customPaywallTraits: [String: Any]?
    
    @State private var state: HeliumPaywallViewState
    @State private var didConfigureContext = false
    @State private var loadingBudgetExpired = false
    
    /// Creates a new paywall view for the specified trigger with default loading view
    ///
    /// - Parameters:
    ///   - trigger: The trigger name to display a paywall for
    ///   - eventHandlers: Optional event handlers for paywall lifecycle events
    ///   - customPaywallTraits: Optional custom traits for paywall personalization
    ///   - fallbackView: View to show when paywall is unavailable
    public init(
        trigger: String,
        eventHandlers: PaywallEventHandlers? = nil,
        customPaywallTraits: [String: Any]? = nil,
        @ViewBuilder fallbackView: @escaping (PaywallUnavailableReason) -> FallbackView
    ) {
        self.trigger = trigger
        self.loadingView = nil
        self.fallbackView = fallbackView
        self.eventHandlers = eventHandlers
        self.customPaywallTraits = customPaywallTraits
        
        self._state = State(initialValue: resolvePaywallState(for: trigger))
    }
    
    /// Creates a new paywall view for the specified trigger with custom loading view
    ///
    /// - Parameters:
    ///   - trigger: The trigger name to display a paywall for
    ///   - eventHandlers: Optional event handlers for paywall lifecycle events
    ///   - customPaywallTraits: Optional custom traits for paywall personalization
    ///   - loadingView: Custom view to show while paywall is loading
    ///   - fallbackView: View to show when paywall is unavailable
    public init<LoadingView: View>(
        trigger: String,
        eventHandlers: PaywallEventHandlers? = nil,
        customPaywallTraits: [String: Any]? = nil,
        @ViewBuilder loadingView: @escaping () -> LoadingView,
        @ViewBuilder fallbackView: @escaping (PaywallUnavailableReason) -> FallbackView
    ) {
        self.trigger = trigger
        self.loadingView = { AnyView(loadingView()) }
        self.fallbackView = fallbackView
        self.eventHandlers = eventHandlers
        self.customPaywallTraits = customPaywallTraits
        
        self._state = State(initialValue: resolvePaywallState(for: trigger))
    }
    
    public var body: some View {
        Group {
            switch state {
            case .loading:
                resolvedLoadingView
            case .ready(let paywallView):
                paywallView
            case .unavailable(let reason):
                fallbackView(reason)
            }
        }
        .onAppear {
            configureContextIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("HeliumConfigDownloadComplete"))) { _ in
            if case .loading = state, !loadingBudgetExpired {
                state = resolvePaywallState(for: trigger)
            }
        }
        .task(id: state) {
            // Only start timeout if currently in loading state
            guard case .loading = state else { return }
            
            let loadingBudget = Helium.shared.fallbackConfig?.loadingBudget(for: trigger) ?? HeliumFallbackConfig.defaultLoadingBudget
            
            try? await Task.sleep(nanoseconds: UInt64(loadingBudget * 1_000_000_000))
            
            // After timeout, re-resolve state (will transition to ready or unavailable)
            loadingBudgetExpired = true
            state = resolvePaywallState(for: trigger)
        }
    }
    
    @ViewBuilder
    private var resolvedLoadingView: some View {
        if let userLoadingView = loadingView {
            userLoadingView()
        } else if let configLoadingView = Helium.shared.fallbackConfig?.loadingView(for: trigger) {
            configLoadingView
        } else {
            let backgroundConfig = HeliumFallbackViewManager.shared.getBackgroundConfigForTrigger(trigger)
            HeliumPaywallPresenter.shared.createDefaultLoadingView(backgroundConfig: backgroundConfig)
        }
    }
    
    private func configureContextIfNeeded() {
        guard !didConfigureContext else { return }
        
        HeliumPaywallDelegateWrapper.shared.configurePresentationContext(
            eventService: eventHandlers,
            customPaywallTraits: customPaywallTraits
        )
        
        didConfigureContext = true
    }
}

/// Represents the current state of a paywall view
enum HeliumPaywallViewState: Equatable {
    /// Paywall is currently loading (config/bundles/products fetching)
    case loading
    /// Paywall is ready to display
    case ready(AnyView)
    /// Paywall is unavailable for the given reason
    case unavailable(PaywallUnavailableReason)
    
    static func == (lhs: HeliumPaywallViewState, rhs: HeliumPaywallViewState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading):
            return true
        case (.ready, .ready):
            return true
        case (.unavailable(let lReason), .unavailable(let rReason)):
            return lReason == rReason
        default:
            return false
        }
    }
}

// MARK: - Helper Functions

/// Returns the current state of a paywall for the trigger
fileprivate func resolvePaywallState(for trigger: String) -> HeliumPaywallViewState {
    if shouldShowLoadingState(for: trigger) {
        return .loading
    }
    
    let result = Helium.shared.upsellViewResultFor(trigger: trigger)
    
    if let view = result.view {
        return .ready(view)
    }
    
    if let reason = result.fallbackReason {
        return .unavailable(reason)
    }
    
    return .unavailable(.unknown)
}

/// Determines if loading state should be shown by checking actual download status
fileprivate func shouldShowLoadingState(for trigger: String) -> Bool {
    // Only show loading if enabled for this trigger
    let useLoadingState = Helium.shared.fallbackConfig?.useLoadingState(for: trigger) ?? true
    if !useLoadingState {
        return false
    }
    
    // Check if downloads are in progress or pending
    let downloadStatus = HeliumFetchedConfigManager.shared.downloadStatus
    let heliumDownloadsIncoming = Helium.shared.isInitialized() &&
    (downloadStatus == .notDownloadedYet || downloadStatus == .inProgress)
    
    return heliumDownloadsIncoming
}
