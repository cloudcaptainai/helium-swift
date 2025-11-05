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
/// HeliumPaywallView(
///     trigger: "onboarding",
///     loadingView: {
///         ProgressView()
///     },
///     fallbackView: { reason in
///         Text("Paywall unavailable: \(reason.rawValue)")
///     }
/// )
/// ```
@available(iOS 15.0, *)
public struct HeliumPaywallView<LoadingView: View, FallbackView: View>: View {
    let trigger: String
    let loadingView: () -> LoadingView
    let fallbackView: (PaywallUnavailableReason) -> FallbackView
    let eventHandlers: PaywallEventHandlers?
    let customPaywallTraits: [String: Any]?
    
    @State private var state: HeliumPaywallViewState
    @State private var didConfigureContext = false
    
    /// Creates a new paywall view for the specified trigger
    ///
    /// - Parameters:
    ///   - trigger: The trigger name to display a paywall for
    ///   - eventHandlers: Optional event handlers for paywall lifecycle events
    ///   - customPaywallTraits: Optional custom traits for paywall personalization
    ///   - loadingView: View to show while paywall is loading
    ///   - fallbackView: View to show when paywall is unavailable
    public init(
        trigger: String,
        eventHandlers: PaywallEventHandlers? = nil,
        customPaywallTraits: [String: Any]? = nil,
        @ViewBuilder loadingView: @escaping () -> LoadingView,
        @ViewBuilder fallbackView: @escaping (PaywallUnavailableReason) -> FallbackView
    ) {
        self.trigger = trigger
        self.loadingView = loadingView
        self.fallbackView = fallbackView
        self.eventHandlers = eventHandlers
        self.customPaywallTraits = customPaywallTraits
        
        // Initialize state using file-private helper function
        self._state = State(initialValue: resolvePaywallState(for: trigger))
    }
    
    public var body: some View {
        Group {
            switch state {
            case .loading:
                loadingView()
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
            if case .loading = state {
                state = resolvePaywallState(for: trigger)
            }
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
enum HeliumPaywallViewState {
    /// Paywall is currently loading (config/bundles/products fetching)
    case loading
    /// Paywall is ready to display
    case ready(AnyView)
    /// Paywall is unavailable for the given reason
    case unavailable(PaywallUnavailableReason)
}

// MARK: - Helper Functions

/// Returns the current state of a paywall for the trigger
fileprivate func resolvePaywallState(for trigger: String) -> HeliumPaywallViewState {
    let result = Helium.shared.upsellViewResultFor(trigger: trigger)
    
    if let view = result.view {
        return .ready(view)
    }
    
    if let reason = result.fallbackReason {
        // Check if we should show loading state
        if shouldShowLoadingState(for: trigger, reason: reason) {
            return .loading
        }
        return .unavailable(reason)
    }
    
    return .unavailable(.unknown)
}

/// Determines if loading state should be shown for the unavailable reason
fileprivate func shouldShowLoadingState(for trigger: String, reason: PaywallUnavailableReason) -> Bool {
    let useLoadingState = Helium.shared.fallbackConfig?.useLoadingState(for: trigger) ?? true
    if !useLoadingState {
        return false
    }
    
    // Show loading only for active fetch states
    switch reason {
    case .configFetchInProgress, .bundlesFetchInProgress, .productsFetchInProgress:
        return true
    default:
        return false
    }
}
