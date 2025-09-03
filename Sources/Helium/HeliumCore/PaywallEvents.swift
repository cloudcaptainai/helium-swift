//
//  PaywallEvents.swift
//  Helium
//
//  V2 Typed Event System for Paywall Events
//

import Foundation

// MARK: - Base Protocol

/// Base protocol for all paywall events in the v2 system
public protocol PaywallEvent {
    var eventName: String { get }
    var timestamp: Date { get }
    
    /// Convert to dictionary for analytics/logging
    func toDictionary() -> [String: Any]
    
    /// Convert to legacy enum format for backward compatibility
    func toLegacyEvent() -> HeliumPaywallEvent
}

// MARK: - Event Context Protocols

/// Events that have paywall context
public protocol PaywallContextEvent: PaywallEvent {
    var triggerName: String { get }
    var paywallName: String { get }
}

/// Events related to products/subscriptions
public protocol ProductEvent: PaywallContextEvent {
    var productId: String { get }
}

// MARK: - Lifecycle Events

public struct PaywallOpenEvent: PaywallContextEvent {
    public let triggerName: String
    public let paywallName: String
    public let viewType: PaywallOpenViewType
    public let timestamp: Date
    
    public init(triggerName: String, paywallName: String, viewType: PaywallOpenViewType, timestamp: Date = Date()) {
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.viewType = viewType
        self.timestamp = timestamp
    }
    
    public var eventName: String { "paywallOpen" }
    
    public func toDictionary() -> [String: Any] {
        return [
            "type": eventName,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "viewType": viewType.rawValue,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .paywallOpen(triggerName: triggerName, paywallTemplateName: paywallName, viewType: viewType.rawValue)
    }
}

public struct PaywallCloseEvent: PaywallContextEvent {
    public let triggerName: String
    public let paywallName: String
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
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .paywallClose(triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

public struct PaywallDismissedEvent: PaywallContextEvent {
    public let triggerName: String
    public let paywallName: String
    public let dismissAll: Bool
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
            "dismissAll": dismissAll,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .paywallDismissed(triggerName: triggerName, paywallTemplateName: paywallName, dismissAll: dismissAll)
    }
}

public struct PaywallOpenFailedEvent: PaywallContextEvent {
    public let triggerName: String
    public let paywallName: String
    public let timestamp: Date
    
    public init(triggerName: String, paywallName: String, timestamp: Date = Date()) {
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.timestamp = timestamp
    }
    
    public var eventName: String { "paywallOpenFailed" }
    
    public func toDictionary() -> [String: Any] {
        return [
            "type": eventName,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .paywallOpenFailed(triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

public struct PaywallSkippedEvent: PaywallEvent {
    public let triggerName: String
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

// MARK: - Purchase Events

public struct ProductSelectedEvent: ProductEvent {
    public let productId: String
    public let triggerName: String
    public let paywallName: String
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
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .offerSelected(productKey: productId, triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

public struct PurchasePressedEvent: ProductEvent {
    public let productId: String
    public let triggerName: String
    public let paywallName: String
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
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .subscriptionPressed(productKey: productId, triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

public struct PurchaseSucceededEvent: ProductEvent {
    public let productId: String
    public let triggerName: String
    public let paywallName: String
    public let timestamp: Date
    
    public init(productId: String, triggerName: String, paywallName: String, timestamp: Date = Date()) {
        self.productId = productId
        self.triggerName = triggerName
        self.paywallName = paywallName
        self.timestamp = timestamp
    }
    
    public var eventName: String { "purchaseSucceeded" }
    
    public func toDictionary() -> [String: Any] {
        return [
            "type": eventName,
            "productId": productId,
            "triggerName": triggerName,
            "paywallName": paywallName,
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .subscriptionSucceeded(productKey: productId, triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

public struct PurchaseCancelledEvent: ProductEvent {
    public let productId: String
    public let triggerName: String
    public let paywallName: String
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
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .subscriptionCancelled(productKey: productId, triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

public struct PurchaseFailedEvent: ProductEvent {
    public let productId: String
    public let triggerName: String
    public let paywallName: String
    public let error: Error?
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

public struct PurchaseRestoredEvent: ProductEvent {
    public let productId: String
    public let triggerName: String
    public let paywallName: String
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
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .subscriptionRestored(productKey: productId, triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

public struct PurchaseRestoreFailedEvent: PaywallContextEvent {
    public let triggerName: String
    public let paywallName: String
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
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .subscriptionRestoreFailed(triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

public struct PurchasePendingEvent: ProductEvent {
    public let productId: String
    public let triggerName: String
    public let paywallName: String
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
            "timestamp": timestamp.timeIntervalSince1970
        ]
    }
    
    public func toLegacyEvent() -> HeliumPaywallEvent {
        return .subscriptionPending(productKey: productId, triggerName: triggerName, paywallTemplateName: paywallName)
    }
}

// MARK: - System Events

public struct InitializeStartEvent: PaywallEvent {
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

public struct PaywallsDownloadSuccessEvent: PaywallEvent {
    public let downloadTimeTakenMS: UInt64?
    public let imagesDownloadTimeTakenMS: UInt64?
    public let fontsDownloadTimeTakenMS: UInt64?
    public let bundleDownloadTimeMS: UInt64?
    public let numAttempts: Int?
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

public struct PaywallsDownloadErrorEvent: PaywallEvent {
    public let error: String
    public let numAttempts: Int?
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

public struct PaywallWebViewRenderedEvent: PaywallContextEvent {
    public let triggerName: String
    public let paywallName: String
    public let webviewRenderTimeTakenMS: UInt64?
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
