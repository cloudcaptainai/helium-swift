//
//  PaywallEvents.swift
//  Helium
//
//  V2 Typed Event System for Paywall Events
//

import Foundation

// MARK: - Base Protocol

/// Base protocol for all paywall events in the v2 system
public protocol HeliumEvent {
    var eventName: String { get }
    var timestamp: Date { get }
    
    /// Convert to dictionary for analytics/logging
    func toDictionary() -> [String: Any]
    
    /// Convert to legacy enum format for backward compatibility
    func toLegacyEvent() -> HeliumPaywallEvent
}

// MARK: - Event Context Protocols

/// Events that have paywall context
public protocol PaywallContextEvent: HeliumEvent {
    var triggerName: String { get }
    var paywallName: String { get }
    var isSecondTry: Bool { get }
}

extension PaywallContextEvent {
    public var isSecondTry: Bool {
        HeliumPaywallPresenter.shared.isSecondTryPaywall(trigger: triggerName)
    }
}

/// Events related to products/subscriptions
public protocol ProductEvent: PaywallContextEvent {
    var productId: String { get }
}

// MARK: - Lifecycle Events

/// Event fired when a paywall is displayed to the user
/// - Note: Event fired when a paywall becomes visible on screen via onReceive of presentationState.isOpen changing to true. Fired by logImpression() when paywall view's onAppear is called or presentation state changes.
public struct PaywallOpenEvent: PaywallContextEvent {
    /// The trigger identifier that caused this paywall to be shown
    /// - Note: Corresponds to trigger key in Helium dashboard (e.g., "premium_upgrade", "onboarding")
    public let triggerName: String
    
    /// The name/identifier of the paywall template being displayed
    public let paywallName: String
    
    /// How the paywall was presented
    /// - Note: Values: .presented (modal), .triggered (SwiftUI view modifier), .embedded (inline in view hierarchy)
    public let viewType: PaywallOpenViewType
    
    /// How long loading state was shown for in milliseconds. Will be nil if no loading state shown.
    public let loadTimeTakenMS: UInt64?
    
    /// Loading budget for this trigger in milliseconds. Will be nil if no loading state shown.
    public let loadingBudgetMS: UInt64?
    
    /// When this event occurred
    public let timestamp: Date
    
    public init(
        triggerName: String, paywallName: String, viewType: PaywallOpenViewType,
        loadTimeTakenMS: UInt64? = nil, loadingBudgetMS: UInt64? = nil,
        timestamp: Date = Date()
    ) {
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.viewType = viewType
        self.loadTimeTakenMS = loadTimeTakenMS
        self.loadingBudgetMS = loadingBudgetMS
        self.timestamp = timestamp
    }
    
    public var eventName: String { "paywallOpen" }
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": eventName,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "isSecondTry": isSecondTry,
            "viewType": viewType.rawValue,
            "timestamp": timestamp.timeIntervalSince1970
        ]
        if let loadTimeTakenMS {
            dict["loadTimeTakenMS"] = loadTimeTakenMS
        }
        if let loadingBudgetMS {
            dict["loadingBudgetMS"] = loadingBudgetMS
        }
        return dict
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .paywallOpen(triggerName: triggerName, paywallTemplateName: paywallName, viewType: viewType.rawValue, loadTimeTakenMS: loadTimeTakenMS, loadingBudgetMS: loadingBudgetMS)
    }
}

/// Event fired when a paywall is closed
/// - Note: Event fired when a paywall disappears from screen via onReceive of presentationState.isOpen changing to false. Fired by logClosure() when the paywall view is no longer visible.
public struct PaywallCloseEvent: PaywallContextEvent {
    /// The trigger identifier for the paywall that was closed
    /// - Note: Corresponds to trigger key in Helium dashboard
    public let triggerName: String
    
    /// The name/identifier of the paywall template that was closed
    /// - Note: Template name from Helium configuration
    public let paywallName: String
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(triggerName: String, paywallName: String, timestamp: Date = Date()) {
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.timestamp = timestamp
    }
    
    public var eventName: String { "paywallClose" }
    
    public func toDictionary() -> [String: Any] {
        return [
            "type": eventName,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "isSecondTry": isSecondTry,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .paywallClose(triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

/// Event fired when user dismisses a paywall
/// - Note: Event fired when dismiss() or dismissAll() is called from JavaScript or native code (user taps X button). Fired BEFORE PaywallCloseEvent when dispatchEvent parameter is true.
public struct PaywallDismissedEvent: PaywallContextEvent {
    /// The trigger identifier for the dismissed paywall
    /// - Note: Corresponds to trigger key in Helium dashboard
    public let triggerName: String
    
    /// The name/identifier of the paywall template that was dismissed
    /// - Note: Template name from Helium configuration
    public let paywallName: String
    
    /// Whether all paywalls in the stack should be dismissed
    /// - Note: true = dismissAll() was called (dismiss entire stack), false = dismiss() was called (dismiss only current)
    public let dismissAll: Bool
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(triggerName: String, paywallName: String, dismissAll: Bool = false, timestamp: Date = Date()) {
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.dismissAll = dismissAll
        self.timestamp = timestamp
    }
    
    public var eventName: String { "paywallDismissed" }
    
    public func toDictionary() -> [String: Any] {
        return [
            "type": eventName,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "isSecondTry": isSecondTry,
            "dismissAll": dismissAll,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .paywallDismissed(triggerName: triggerName, paywallTemplateName: paywallName, dismissAll: dismissAll)
    }
}

public struct PaywallOpenFailedEvent: PaywallContextEvent {
    /// The trigger identifier for the paywall that failed to open
    /// - Note: Corresponds to trigger key in Helium dashboard
    public let triggerName: String
    
    /// The name/identifier of the paywall template that failed to open
    /// - Note: Template name from Helium configuration (may be empty if paywall not found)
    public let paywallName: String
    
    /// Optional error message describing why the paywall failed to open
    /// - Note: Provides context for debugging (e.g., "WebView failed to load", "Template not found")
    public let error: String
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(triggerName: String, paywallName: String, error: String, timestamp: Date = Date()) {
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.error = error
        self.timestamp = timestamp
    }
    
    public var eventName: String { "paywallOpenFailed" }
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": eventName,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "isSecondTry": isSecondTry,
            "error": error,
            "timestamp": timestamp.timeIntervalSince1970
        ]
        return dict
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .paywallOpenFailed(triggerName: triggerName, paywallTemplateName: paywallName, error: error)
    }
}

public struct PaywallSkippedEvent: HeliumEvent {
    /// The trigger identifier that was skipped
    /// - Note: Trigger key from Helium dashboard where shouldShow=false in config
    public let triggerName: String
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(triggerName: String, timestamp: Date = Date()) {
        self.triggerName = triggerName
        self.timestamp = timestamp
    }
    
    public var eventName: String { "paywallSkipped" }
    
    public func toDictionary() -> [String: Any] {
        return [
            "type": eventName,
            "triggerName": triggerName,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .paywallSkipped(triggerName: triggerName)
    }
}

/// Event fired when user presses a non-purchase button in the paywall
/// - Note: Event fired when onCTAPress() is called from JavaScript message handler for non-purchase buttons. Triggered by 'cta-pressed' message from WebView when user taps custom buttons.
public struct PaywallButtonPressedEvent: PaywallContextEvent {
    /// The identifier/name of the button that was pressed
    /// - Note: Value comes from componentName field in 'cta-pressed' JavaScript message (e.g., "learn_more", "terms_of_service")
    public let buttonName: String
    
    /// The trigger identifier for the paywall containing this button
    /// - Note: Corresponds to trigger key in Helium dashboard
    public let triggerName: String
    
    /// The name/identifier of the paywall template containing this button
    /// - Note: Template name from Helium configuration
    public let paywallName: String
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(buttonName: String, triggerName: String, paywallName: String, timestamp: Date = Date()) {
        self.buttonName = buttonName
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.timestamp = timestamp
    }
    
    public var eventName: String { "paywallButtonPressed" }
    
    public func toDictionary() -> [String: Any] {
        return [
            "type": eventName,
            "buttonName": buttonName,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "isSecondTry": isSecondTry,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .ctaPressed(ctaName: buttonName, triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

// MARK: - Purchase Events

/// Event fired when user selects a product
/// - Note: Event fired when selectProduct() is called from JavaScript 'select-product' message. Occurs when user taps on a product option in the paywall UI to select it.
public struct ProductSelectedEvent: ProductEvent {
    /// The product identifier that was selected
    /// - Note: StoreKit product ID from App Store Connect (e.g., "com.app.premium.monthly")
    public let productId: String
    
    /// The trigger identifier for the paywall where selection occurred
    /// - Note: Corresponds to trigger key in Helium dashboard
    public let triggerName: String
    
    /// The name/identifier of the paywall template where selection occurred
    /// - Note: Template name from Helium configuration
    public let paywallName: String
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(productId: String, triggerName: String, paywallName: String, timestamp: Date = Date()) {
        self.productId = productId
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.timestamp = timestamp
    }
    
    public var eventName: String { "productSelected" }
    
    public func toDictionary() -> [String: Any] {
        return [
            "type": eventName,
            "productId": productId,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "isSecondTry": isSecondTry,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .offerSelected(productKey: productId, triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

/// Event fired when user initiates a purchase
/// - Note: Event fired immediately when makePurchase() is called, before StoreKit transaction begins. Always followed by exactly one of: PurchaseSucceeded, PurchaseFailed, PurchaseCancelled, or PurchasePending.
public struct PurchasePressedEvent: ProductEvent {
    /// The product identifier being purchased
    /// - Note: StoreKit product ID from App Store Connect
    public let productId: String
    
    /// The trigger identifier for the paywall where purchase was initiated
    /// - Note: Corresponds to trigger key in Helium dashboard
    public let triggerName: String
    
    /// The name/identifier of the paywall template where purchase was initiated
    /// - Note: Template name from Helium configuration
    public let paywallName: String
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(productId: String, triggerName: String, paywallName: String, timestamp: Date = Date()) {
        self.productId = productId
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.timestamp = timestamp
    }
    
    public var eventName: String { "purchasePressed" }
    
    public func toDictionary() -> [String: Any] {
        return [
            "type": eventName,
            "productId": productId,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "isSecondTry": isSecondTry,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .subscriptionPressed(productKey: productId, triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

/// Event fired when a purchase completes successfully
/// - Note: Event fired when StoreKit returns .purchased status from makePurchase() delegate method. Transaction has been verified and finished by StoreKit.
public struct PurchaseSucceededEvent: ProductEvent {
    /// The product identifier that was successfully purchased
    /// - Note: StoreKit product ID from App Store Connect
    public let productId: String
    
    /// The trigger identifier for the paywall where purchase succeeded
    /// - Note: Corresponds to trigger key in Helium dashboard
    public let triggerName: String
    
    /// The name/identifier of the paywall template where purchase succeeded
    /// - Note: Template name from Helium configuration
    public let paywallName: String
    
    /// StoreKit transaction ID
    public let storeKitTransactionId: String?
    
    /// StoreKit original transaction ID
    public let storeKitOriginalTransactionId: String?
    
    /// Time taken to retrieve StoreKit transaction IDs after purchase successs in milliseconds
    public let skPostPurchaseTxnTimeMS: UInt64?
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(productId: String, triggerName: String, paywallName: String, storeKitTransactionId: String?, storeKitOriginalTransactionId: String?, skPostPurchaseTxnTimeMS: UInt64? = nil, timestamp: Date = Date()) {
        self.productId = productId
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.storeKitTransactionId = storeKitTransactionId
        self.storeKitOriginalTransactionId = storeKitOriginalTransactionId
        self.skPostPurchaseTxnTimeMS = skPostPurchaseTxnTimeMS
        self.timestamp = timestamp
    }
    
    public var eventName: String { "purchaseSucceeded" }
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": eventName,
            "productId": productId,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "isSecondTry": isSecondTry,
            "timestamp": timestamp.timeIntervalSince1970
        ]
        if let storeKitTransactionId {
            dict["storeKitTransactionId"] = storeKitTransactionId
        }
        if let storeKitOriginalTransactionId {
            dict["storeKitOriginalTransactionId"] = storeKitOriginalTransactionId
        }
        if let skPostPurchaseTxnTimeMS {
            dict["skPostPurchaseTxnTimeMS"] = skPostPurchaseTxnTimeMS
        }
        return dict
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .subscriptionSucceeded(productKey: productId, triggerName: triggerName, paywallTemplateName: paywallName, storeKitTransactionId: storeKitTransactionId, storeKitOriginalTransactionId: storeKitOriginalTransactionId, skPostPurchaseTxnTimeMS: skPostPurchaseTxnTimeMS)
    }
}

/// Event fired when StoreKit returns .cancelled status from makePurchase() delegate method
/// - Note: User explicitly cancelled in StoreKit payment sheet
public struct PurchaseCancelledEvent: ProductEvent {
    /// The product identifier that user was attempting to purchase
    /// - Note: StoreKit product ID from App Store Connect
    public let productId: String
    
    /// The trigger identifier for the paywall where purchase was cancelled
    /// - Note: Corresponds to trigger key in Helium dashboard
    public let triggerName: String
    
    /// The name/identifier of the paywall template where purchase was cancelled
    /// - Note: Template name from Helium configuration
    public let paywallName: String
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(productId: String, triggerName: String, paywallName: String, timestamp: Date = Date()) {
        self.productId = productId
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.timestamp = timestamp
    }
    
    public var eventName: String { "purchaseCancelled" }
    
    public func toDictionary() -> [String: Any] {
        return [
            "type": eventName,
            "productId": productId,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "isSecondTry": isSecondTry,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .subscriptionCancelled(productKey: productId, triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

/// Event fired when a purchase fails
/// - Note: Event fired when StoreKit returns .failed status from makePurchase() delegate method. Contains the actual Error object from StoreKit for debugging.
public struct PurchaseFailedEvent: ProductEvent {
    /// The product identifier that failed to purchase
    /// - Note: StoreKit product ID from App Store Connect
    public let productId: String
    
    /// The trigger identifier for the paywall where purchase failed
    /// - Note: Corresponds to trigger key in Helium dashboard
    public let triggerName: String
    
    /// The name/identifier of the paywall template where purchase failed
    /// - Note: Template name from Helium configuration
    public let paywallName: String
    
    /// The error that caused the purchase to fail
    /// - Note: Contains StoreKit error for debugging (e.g., SKError.paymentCancelled, network errors)
    public let error: Error?
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(productId: String, triggerName: String, paywallName: String, error: Error? = nil, timestamp: Date = Date()) {
        self.productId = productId
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.error = error
        self.timestamp = timestamp
    }
    
    public var eventName: String { "purchaseFailed" }
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": eventName,
            "productId": productId,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "isSecondTry": isSecondTry,
            "timestamp": timestamp.timeIntervalSince1970
        ]
        if let error = error {
            dict["error"] = error.localizedDescription
        }
        return dict
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .subscriptionFailed(productKey: productId, triggerName: triggerName, paywallTemplateName: paywallName, error: error?.localizedDescription)
    }
}

/// Event fired when StoreKit returns .restored status from makePurchase() or restorePurchases() returns true
/// - Note: Previous purchase has been successfully restored
public struct PurchaseRestoredEvent: ProductEvent {
    /// The product identifier that was restored
    /// - Note: Set to "HELIUM_GENERIC_PRODUCT" when restoring all purchases via restorePurchases()
    public let productId: String
    
    /// The trigger identifier for the paywall where restore occurred
    /// - Note: Corresponds to trigger key in Helium dashboard
    public let triggerName: String
    
    /// The name/identifier of the paywall template where restore occurred
    /// - Note: Template name from Helium configuration
    public let paywallName: String
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(productId: String, triggerName: String, paywallName: String, timestamp: Date = Date()) {
        self.productId = productId
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.timestamp = timestamp
    }
    
    public var eventName: String { "purchaseRestored" }
    
    public func toDictionary() -> [String: Any] {
        return [
            "type": eventName,
            "productId": productId,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "isSecondTry": isSecondTry,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .subscriptionRestored(productKey: productId, triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

/// Event fired when restorePurchases() delegate method returns false
/// - Note: No previous purchases found to restore or restore process failed
public struct PurchaseRestoreFailedEvent: PaywallContextEvent {
    /// The trigger identifier for the paywall where restore was attempted
    /// - Note: Corresponds to trigger key in Helium dashboard
    public let triggerName: String
    
    /// The name/identifier of the paywall template where restore was attempted
    /// - Note: Template name from Helium configuration
    public let paywallName: String
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(triggerName: String, paywallName: String, timestamp: Date = Date()) {
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.timestamp = timestamp
    }
    
    public var eventName: String { "purchaseRestoreFailed" }
    
    public func toDictionary() -> [String: Any] {
        return [
            "type": eventName,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "isSecondTry": isSecondTry,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .subscriptionRestoreFailed(triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

/// Event fired when StoreKit returns .pending status (e.g., waiting for parental approval)
/// - Note: Transaction is awaiting external action before completion
public struct PurchasePendingEvent: ProductEvent {
    /// The product identifier that is pending
    /// - Note: StoreKit product ID from App Store Connect
    public let productId: String
    
    /// The trigger identifier for the paywall where purchase is pending
    /// - Note: Corresponds to trigger key in Helium dashboard
    public let triggerName: String
    
    /// The name/identifier of the paywall template where purchase is pending
    /// - Note: Template name from Helium configuration
    public let paywallName: String
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(productId: String, triggerName: String, paywallName: String, timestamp: Date = Date()) {
        self.productId = productId
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.timestamp = timestamp
    }
    
    public var eventName: String { "purchasePending" }
    
    public func toDictionary() -> [String: Any] {
        return [
            "type": eventName,
            "productId": productId,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "isSecondTry": isSecondTry,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .subscriptionPending(productKey: productId, triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

// MARK: - System Events

/// Event fired at the beginning of Helium.shared.initialize() method
/// - Note: Marks the start of SDK initialization process
public struct InitializeStartEvent: HeliumEvent {
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(timestamp: Date = Date()) {
        self.timestamp = timestamp
    }
    
    public var eventName: String { "initializeStart" }
    
    public func toDictionary() -> [String: Any] {
        return [
            "type": eventName,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .initializeStart
    }
}

/// Event fired after successful network fetch and parsing of paywall configuration from Helium servers
/// - Note: Includes timing metrics for download, image fetch, font fetch, and bundle download
public struct PaywallsDownloadSuccessEvent: HeliumEvent {
    /// Total time taken to download configuration in milliseconds
    /// - Note: Measured from start of network request to successful response parsing
    public let downloadTimeTakenMS: UInt64?
    
    /// Time taken to download images in milliseconds
    /// - Note: Total time for all image assets referenced in paywall templates
    public let imagesDownloadTimeTakenMS: UInt64?
    
    /// Time taken to download fonts in milliseconds
    /// - Note: Total time for all custom font files used in paywall templates
    public let fontsDownloadTimeTakenMS: UInt64?
    
    /// Time taken to download bundle assets in milliseconds
    /// - Note: Time to download JavaScript/CSS bundles for web-based paywalls
    public let bundleDownloadTimeMS: UInt64?
    
    /// Number of retry attempts before success
    /// - Note: 1 = succeeded on first try, higher values indicate retries were needed
    public let numAttempts: Int?
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(
        downloadTimeTakenMS: UInt64? = nil,
        imagesDownloadTimeTakenMS: UInt64? = nil,
        fontsDownloadTimeTakenMS: UInt64? = nil,
        bundleDownloadTimeMS: UInt64? = nil,
        numAttempts: Int? = nil,
        timestamp: Date = Date()
    ) {
        self.downloadTimeTakenMS = downloadTimeTakenMS
        self.imagesDownloadTimeTakenMS = imagesDownloadTimeTakenMS
        self.fontsDownloadTimeTakenMS = fontsDownloadTimeTakenMS
        self.bundleDownloadTimeMS = bundleDownloadTimeMS
        self.numAttempts = numAttempts
        self.timestamp = timestamp
    }
    
    public var eventName: String { "paywallsDownloadSuccess" }
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": eventName,
            "timestamp": timestamp.timeIntervalSince1970
        ]
        if let downloadTime = downloadTimeTakenMS {
            dict["downloadTimeTakenMS"] = downloadTime
        }
        if let imagesTime = imagesDownloadTimeTakenMS {
            dict["imagesDownloadTimeTakenMS"] = imagesTime
        }
        if let fontsTime = fontsDownloadTimeTakenMS {
            dict["fontsDownloadTimeTakenMS"] = fontsTime
        }
        if let bundleTime = bundleDownloadTimeMS {
            dict["bundleDownloadTimeMS"] = bundleTime
        }
        if let attempts = numAttempts {
            dict["numAttempts"] = attempts
        }
        return dict
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        // For legacy compatibility, we need to provide a configId - use a dummy UUID
        let dummyConfigId = UUID()
        return .paywallsDownloadSuccess(
            configId: dummyConfigId,
            downloadTimeTakenMS: downloadTimeTakenMS,
            imagesDownloadTimeTakenMS: imagesDownloadTimeTakenMS,
            fontsDownloadTimeTakenMS: fontsDownloadTimeTakenMS,
            bundleDownloadTimeMS: bundleDownloadTimeMS,
            numAttempts: numAttempts
        )
    }
}

/// Event fired when paywall configuration download fails
/// - Note: Event fired when network fetch or parsing of paywall configuration fails. Fired after all retry attempts have been exhausted.
public struct PaywallsDownloadErrorEvent: HeliumEvent {
    /// The error message describing what went wrong
    /// - Note: Network error, parsing error, or timeout message
    public let error: String
    
    /// Number of retry attempts made before giving up
    /// - Note: Includes initial attempt plus any retries before failure
    public let numAttempts: Int?
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(error: String, numAttempts: Int? = nil, timestamp: Date = Date()) {
        self.error = error
        self.numAttempts = numAttempts
        self.timestamp = timestamp
    }
    
    public var eventName: String { "paywallsDownloadError" }
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": eventName,
            "error": error,
            "timestamp": timestamp.timeIntervalSince1970
        ]
        if let attempts = numAttempts {
            dict["numAttempts"] = attempts
        }
        return dict
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .paywallsDownloadError(error: error, numAttempts: numAttempts)
    }
}

/// Event fired when paywall web view finishes rendering
/// - Note: Event fired when WebView's didFinish navigation delegate method is called and document.readyState is 'complete'. Includes render time in milliseconds from start of load to completion.
public struct PaywallWebViewRenderedEvent: PaywallContextEvent {
    /// The trigger identifier for the rendered paywall
    /// - Note: Corresponds to trigger key in Helium dashboard
    public let triggerName: String
    
    /// The name/identifier of the paywall template that was rendered
    /// - Note: Template name from Helium configuration
    public let paywallName: String
    
    /// Time taken to render the WebView in milliseconds
    /// - Note: Measured from WebView load start to didFinish navigation with document.readyState='complete'
    public let webviewRenderTimeTakenMS: UInt64?
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(triggerName: String, paywallName: String, webviewRenderTimeTakenMS: UInt64? = nil, timestamp: Date = Date()) {
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.webviewRenderTimeTakenMS = webviewRenderTimeTakenMS
        self.timestamp = timestamp
    }
    
    public var eventName: String { "paywallWebViewRendered" }
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": eventName,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "isSecondTry": isSecondTry,
            "timestamp": timestamp.timeIntervalSince1970
        ]
        if let renderTime = webviewRenderTimeTakenMS {
            dict["webviewRenderTimeTakenMS"] = renderTime
        }
        return dict
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .paywallWebViewRendered(
            triggerName: triggerName,
            paywallTemplateName: paywallName,
            webviewRenderTimeTakenMS: webviewRenderTimeTakenMS
        )
    }
}

// MARK: - Experiment Events

/// Event fired when a user is allocated to an experiment variant
/// - Note: Fired once per trigger when a user is first assigned to an experiment variant. Contains complete experiment allocation details including variant information, targeting criteria, and hash bucketing.
public struct UserAllocatedEvent: HeliumEvent {
    /// Complete experiment allocation information
    /// - Note: Includes experiment details, variant selection, targeting, and allocation metadata
    public let experimentInfo: ExperimentInfo
    
    /// When this event occurred
    /// - Note: Captured using Date() at event creation time
    public let timestamp: Date
    
    public init(experimentInfo: ExperimentInfo, timestamp: Date = Date()) {
        self.experimentInfo = experimentInfo
        self.timestamp = timestamp
    }
    
    public var eventName: String { "userAllocated" }
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": eventName,
            "timestamp": timestamp.timeIntervalSince1970
        ]
        
        // Merge in all experiment info fields with prefixed keys
        let experimentDict = experimentInfo.toDictionaryWithPrefix()
        for (key, value) in experimentDict {
            dict[key] = value
        }
        
        return dict
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        // No legacy event equivalent - this is a new event type
        // Return a generic event that won't cause issues
        return .initializeStart
    }
}
