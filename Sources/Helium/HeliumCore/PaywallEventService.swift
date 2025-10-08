//
//  PaywallEventHandlers.swift
//  Helium
//
//  Event handler service for paywall lifecycle events using the v2 typed event system
//

import Foundation

/// Service for handling essential paywall lifecycle events with a builder pattern API
/// - Note: Provides handlers for the key paywall events: open, close, dismiss, and purchase success
public struct PaywallEventHandlers {
    
    // MARK: - Event Handlers
    
    /// Called when a paywall is displayed to the user
    /// - Note: Fired when paywall becomes visible on screen (via onAppear or presentation state change)
    public var onOpen: ((PaywallOpenEvent) -> Void)?
    
    /// Called when a paywall is closed for any reason
    /// - Note: This is fired after BOTH onDismissed (user closes) AND onPurchaseSucceeded (successful purchase).
    ///         Use this for cleanup that should happen regardless of how the paywall was closed.
    public var onClose: ((PaywallCloseEvent) -> Void)?
    
    /// Called when user explicitly dismisses a paywall without purchasing
    /// - Note: Fired when user taps the X button or swipes to dismiss. Always followed by onClose.
    public var onDismissed: ((PaywallDismissedEvent) -> Void)?
    
    /// Called when a purchase completes successfully
    /// - Note: Fired when StoreKit confirms successful purchase. Paywall typically auto-closes after this, triggering onClose.
    public var onPurchaseSucceeded: ((PurchaseSucceededEvent) -> Void)?
    
    /// Called when a paywall fails to open
    /// - Note: Fired when paywall cannot be displayed (e.g., no view available, already presenting, WebView load failure)
    public var onOpenFailed: ((PaywallOpenFailedEvent) -> Void)?
    
    /// Called when a custom action is triggered from the paywall
    /// - Note: Handle arbitrary actions sent from the paywall with custom data
    public var onCustomPaywallAction: ((CustomPaywallActionEvent) -> Void)?
    
    // MARK: - Initializer
    
    public init() {}
    
    // MARK: - Internal Handler
    
    /// Internal method to handle v2 paywall events and dispatch to appropriate handlers
    internal func handleEvent(_ event: HeliumEvent) {
        switch event {
        case let e as PaywallOpenEvent:
            onOpen?(e)
            
        case let e as PaywallCloseEvent:
            onClose?(e)
            
        case let e as PaywallDismissedEvent:
            onDismissed?(e)
            
        case let e as PurchaseSucceededEvent:
            onPurchaseSucceeded?(e)
            
        case let e as PaywallOpenFailedEvent:
            onOpenFailed?(e)
            
        case let e as CustomPaywallActionEvent:
            onCustomPaywallAction?(e)
            
        default:
            // Ignore events we don't have handlers for
            break
        }
    }
}

// MARK: - Builder Pattern Extension

extension PaywallEventHandlers {
    
    /// Set handler for when a paywall is displayed
    /// - Note: Use this to track when users see your paywall (impressions)
    public func onOpen(_ handler: @escaping (PaywallOpenEvent) -> Void) -> PaywallEventHandlers {
        var service = self
        service.onOpen = handler
        return service
    }
    
    /// Set handler for when a paywall is closed
    /// - Note: This fires after BOTH dismissal and successful purchase. Use for cleanup logic.
    public func onClose(_ handler: @escaping (PaywallCloseEvent) -> Void) -> PaywallEventHandlers {
        var service = self
        service.onClose = handler
        return service
    }
    
    /// Set handler for when user dismisses a paywall
    /// - Note: Track when users close without purchasing. Always followed by onClose.
    public func onDismissed(_ handler: @escaping (PaywallDismissedEvent) -> Void) -> PaywallEventHandlers {
        var service = self
        service.onDismissed = handler
        return service
    }
    
    /// Set handler for when a purchase completes successfully
    /// - Note: Track conversions. Paywall auto-closes after, triggering onClose.
    public func onPurchaseSucceeded(_ handler: @escaping (PurchaseSucceededEvent) -> Void) -> PaywallEventHandlers {
        var service = self
        service.onPurchaseSucceeded = handler
        return service
    }
    
    /// Set handler for when a paywall fails to open
    /// - Note: Track paywall presentation failures. Useful for debugging and monitoring.
    public func onOpenFailed(_ handler: @escaping (PaywallOpenFailedEvent) -> Void) -> PaywallEventHandlers {
        var service = self
        service.onOpenFailed = handler
        return service
    }
    
    /// Set handler for custom paywall actions
    /// - Note: Handle arbitrary actions sent from the paywall with custom data
    public func onCustomPaywallAction(_ handler: @escaping (CustomPaywallActionEvent) -> Void) -> PaywallEventHandlers {
        var service = self
        service.onCustomPaywallAction = handler
        return service
    }
}

// MARK: - Convenience Extensions

extension PaywallEventHandlers {
    
    /// Create a service with optional handlers
    /// - Note: Provides a quick way to set up tracking for the paywall lifecycle. All handlers are optional.
    public static func withHandlers(
        onOpen: ((PaywallOpenEvent) -> Void)? = nil,
        onClose: ((PaywallCloseEvent) -> Void)? = nil,
        onDismissed: ((PaywallDismissedEvent) -> Void)? = nil,
        onPurchaseSucceeded: ((PurchaseSucceededEvent) -> Void)? = nil,
        onOpenFailed: ((PaywallOpenFailedEvent) -> Void)? = nil,
        onCustomPaywallAction: ((CustomPaywallActionEvent) -> Void)? = nil
    ) -> PaywallEventHandlers {
        var service = PaywallEventHandlers()
        if let onOpen = onOpen {
            service = service.onOpen(onOpen)
        }
        if let onClose = onClose {
            service = service.onClose(onClose)
        }
        if let onDismissed = onDismissed {
            service = service.onDismissed(onDismissed)
        }
        if let onPurchaseSucceeded = onPurchaseSucceeded {
            service = service.onPurchaseSucceeded(onPurchaseSucceeded)
        }
        if let onOpenFailed = onOpenFailed {
            service = service.onOpenFailed(onOpenFailed)
        }
        if let onCustomPaywallAction = onCustomPaywallAction {
            service = service.onCustomPaywallAction(onCustomPaywallAction)
        }
        return service
    }
}
