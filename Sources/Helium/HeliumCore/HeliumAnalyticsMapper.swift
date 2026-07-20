//
//  HeliumAnalyticsMapper.swift
//
//  Maps HeliumEvent instances to the analytics payload sent under the
//  `heliumEvent` key of HeliumPaywallLoggedEvent. Mirrors Android's
//  AnalyticsMapper. The keys and `type` discriminators here are the analytics
//  wire format — they intentionally differ from HeliumEvent.eventName /
//  toDictionary() (the public listener surface) and must not change without a
//  backend migration.
//
//  Every event's mapping lives here as `analyticsEventName` /
//  `analyticsPayload()` conformances — HeliumEvent protocol requirements with
//  no default implementation, so a new event type will not compile until its
//  mapping is added.
//

import Foundation

/// Entry points for the analytics pipeline (Android naming parity).
enum HeliumAnalyticsMapper {

    /// Builds the analytics payload dictionary for an event.
    static func mapToAnalyticsPayload(_ event: HeliumEvent) -> [String: Any] {
        event.analyticsPayload()
    }

    /// Analytics event name for an event.
    static func getEventName(_ event: HeliumEvent) -> String {
        event.analyticsEventName
    }

    /// Trigger name used for logged-event enrichment (experiment/paywall lookup).
    static func getTriggerName(_ event: HeliumEvent) -> String? {
        switch event {
        case let e as PaywallContextEvent: return e.triggerName
        case let e as PaywallSkippedEvent: return e.triggerName
        case let e as UserAllocatedEvent: return e.trigger
        default: return nil
        }
    }

    /// Paywall template name used for logged-event enrichment.
    static func getPaywallTemplateName(_ event: HeliumEvent) -> String? {
        (event as? PaywallContextEvent)?.paywallName
    }
}

// MARK: - Shared payload builders

extension PaywallContextEvent {
    /// The fields uniform across every context event on the wire:
    /// `type`, `triggerName`, `paywallTemplateName`.
    fileprivate func contextAnalyticsPayload() -> [String: Any] {
        [
            "type": analyticsEventName,
            "triggerName": triggerName,
            "paywallTemplateName": paywallName,
        ]
    }
}

extension ProductEvent {
    /// Context fields plus `productKey`.
    fileprivate func productAnalyticsPayload() -> [String: Any] {
        var payload = contextAnalyticsPayload()
        payload["productKey"] = productId
        return payload
    }
}

// MARK: - Lifecycle events

extension PaywallOpenEvent {
    public var analyticsEventName: String { "paywallOpen" }

    public func analyticsPayload() -> [String: Any] {
        var payload = contextAnalyticsPayload()
        payload["viewType"] = viewType.rawValue
        payload["loadTimeTakenMS"] = loadTimeTakenMS
        payload["loadingBudgetMS"] = loadingBudgetMS
        payload["paywallUnavailableReason"] = paywallUnavailableReason?.rawValue
        payload["newWindowCreated"] = newWindowCreated
        return payload
    }
}

extension PaywallOpenFailedEvent {
    public var analyticsEventName: String { "paywallOpenFailed" }

    public func analyticsPayload() -> [String: Any] {
        var payload = contextAnalyticsPayload()
        payload["errorDescription"] = error
        payload["paywallUnavailableReason"] = paywallUnavailableReason?.rawValue
        payload["loadTimeTakenMS"] = loadTimeTakenMS
        payload["loadingBudgetMS"] = loadingBudgetMS
        payload["newWindowCreated"] = newWindowCreated
        return payload
    }
}

extension PaywallCloseEvent {
    public var analyticsEventName: String { "paywallClose" }

    public func analyticsPayload() -> [String: Any] {
        contextAnalyticsPayload()
    }
}

extension PaywallDismissedEvent {
    public var analyticsEventName: String { "paywallDismissed" }

    public func analyticsPayload() -> [String: Any] {
        var payload = contextAnalyticsPayload()
        payload["dismissAll"] = dismissAll
        return payload
    }
}

extension PaywallSkippedEvent {
    public var analyticsEventName: String { "paywallSkipped" }

    public func analyticsPayload() -> [String: Any] {
        [
            "type": analyticsEventName,
            "triggerName": triggerName,
            "skipReason": skipReason.rawValue,
        ]
    }
}

extension PaywallWebViewRenderedEvent {
    public var analyticsEventName: String { "paywallWebViewRendered" }

    public func analyticsPayload() -> [String: Any] {
        var payload = contextAnalyticsPayload()
        payload["webviewRenderTimeTakenMS"] = webviewRenderTimeTakenMS
        payload["paywallUnavailableReason"] = paywallUnavailableReason?.rawValue
        return payload
    }
}

extension PaywallButtonPressedEvent {
    public var analyticsEventName: String { "ctaPressed" }

    public func analyticsPayload() -> [String: Any] {
        var payload = contextAnalyticsPayload()
        payload["ctaName"] = buttonName
        return payload
    }
}

extension CustomPaywallActionEvent {
    public var analyticsEventName: String { "customPaywallAction" }

    public func analyticsPayload() -> [String: Any] {
        var payload = contextAnalyticsPayload()
        payload["actionName"] = actionName
        if JSONSerialization.isValidJSONObject(params),
           let jsonData = try? JSONSerialization.data(withJSONObject: params),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            payload["params"] = jsonString
        }
        return payload
    }
}

// MARK: - Purchase events

extension ProductSelectedEvent {
    public var analyticsEventName: String { "offerSelected" }

    public func analyticsPayload() -> [String: Any] {
        productAnalyticsPayload()
    }
}

extension PurchasePressedEvent {
    public var analyticsEventName: String { "subscriptionPressed" }

    public func analyticsPayload() -> [String: Any] {
        var payload = productAnalyticsPayload()
        payload["paymentProcessor"] = paymentProcessor.rawValue
        return payload
    }
}

extension PurchaseCancelledEvent {
    public var analyticsEventName: String { "subscriptionCancelled" }

    public func analyticsPayload() -> [String: Any] {
        var payload = productAnalyticsPayload()
        payload["paymentProcessor"] = paymentProcessor.rawValue
        return payload
    }
}

extension PurchaseSucceededEvent {
    public var analyticsEventName: String { "subscriptionSucceeded" }

    public func analyticsPayload() -> [String: Any] {
        var payload = productAnalyticsPayload()
        payload["storeKitTransactionId"] = storeKitTransactionId
        payload["storeKitOriginalTransactionId"] = storeKitOriginalTransactionId
        payload["skPostPurchaseTxnTimeMS"] = skPostPurchaseTxnTimeMS
        payload["canonicalJoinTransactionId"] = storeKitTransactionId
        payload["paymentProcessor"] = paymentProcessor.rawValue
        return payload
    }
}

extension PurchaseFailedEvent {
    public var analyticsEventName: String { "subscriptionFailed" }

    public func analyticsPayload() -> [String: Any] {
        var payload = productAnalyticsPayload()
        payload["errorDescription"] = error?.localizedDescription
        payload["paymentProcessor"] = paymentProcessor.rawValue
        return payload
    }
}

extension PurchaseRestoredEvent {
    public var analyticsEventName: String { "subscriptionRestored" }

    public func analyticsPayload() -> [String: Any] {
        var payload = productAnalyticsPayload()
        payload["restoreOrigin"] = restoreOrigin.rawValue
        return payload
    }
}

extension PurchaseRestoreFailedEvent {
    public var analyticsEventName: String { "subscriptionRestoreFailed" }

    public func analyticsPayload() -> [String: Any] {
        contextAnalyticsPayload()
    }
}

extension PurchaseAlreadyEntitledEvent {
    public var analyticsEventName: String { "purchase_already_entitled" }

    public func analyticsPayload() -> [String: Any] {
        var payload = productAnalyticsPayload()
        payload["storeKitTransactionId"] = storeKitTransactionId
        payload["storeKitOriginalTransactionId"] = storeKitOriginalTransactionId
        payload["canonicalJoinTransactionId"] = storeKitTransactionId
        return payload
    }
}

extension PurchasePendingEvent {
    public var analyticsEventName: String { "subscriptionPending" }

    public func analyticsPayload() -> [String: Any] {
        productAnalyticsPayload()
    }
}

// MARK: - System events

extension InitializeCalledEvent {
    public var analyticsEventName: String { "initializeCalled" }

    public func analyticsPayload() -> [String: Any] {
        ["type": analyticsEventName]
    }
}

extension PaywallsDownloadSuccessEvent {
    public var analyticsEventName: String { "paywallsDownloadSuccess" }

    public func analyticsPayload() -> [String: Any] {
        var payload: [String: Any] = ["type": analyticsEventName]
        payload["downloadTimeTakenMS"] = downloadTimeTakenMS
        payload["imagesDownloadTimeTakenMS"] = imagesDownloadTimeTakenMS
        payload["fontsDownloadTimeTakenMS"] = fontsDownloadTimeTakenMS
        payload["bundleDownloadTimeMS"] = bundleDownloadTimeMS
        payload["localizedPriceTimeMS"] = localizedPriceTimeMS
        payload["localizedPriceSuccess"] = localizedPriceSuccess
        payload["numBundles"] = numBundles
        payload["numBundlesFromCache"] = numBundlesFromCache
        payload["uncachedBundleSizeKB"] = uncachedBundleSizeKB
        payload["numAttempts"] = numAttempts
        payload["numBundleAttempts"] = numBundleAttempts
        payload["totalInitializeTimeMS"] = totalInitializeTimeMS
        return payload
    }
}

extension PaywallsDownloadErrorEvent {
    public var analyticsEventName: String { "paywallsDownloadError" }

    public func analyticsPayload() -> [String: Any] {
        var payload: [String: Any] = ["type": analyticsEventName]
        payload["errorDescription"] = error
        payload["configDownloaded"] = configDownloaded
        payload["downloadTimeTakenMS"] = downloadTimeTakenMS
        payload["bundleDownloadTimeMS"] = bundleDownloadTimeMS
        payload["numBundles"] = numBundles
        payload["numBundlesNotDownloaded"] = numBundlesNotDownloaded
        payload["numAttempts"] = numAttempts
        payload["numBundleAttempts"] = numBundleAttempts
        payload["totalInitializeTimeMS"] = totalInitializeTimeMS
        return payload
    }
}

extension UserAllocatedEvent {
    public var analyticsEventName: String { "userAllocated" }

    public func analyticsPayload() -> [String: Any] {
        // experimentInfo intentionally not included — it rides top-level on
        // HeliumPaywallLoggedEvent.experimentInfo.
        [
            "type": analyticsEventName,
            "triggerName": trigger,
        ]
    }
}
