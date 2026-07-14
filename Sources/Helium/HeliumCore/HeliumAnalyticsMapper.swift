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

import Foundation

enum HeliumAnalyticsMapper {

    /// Builds the analytics payload dictionary for an event.
    ///
    /// Wire-format notes (locked down by AnalyticsPayloadMappingTests):
    /// - `type` uses legacy analytics names from `getEventName`, not `eventName`.
    /// - Errors are keyed `errorDescription`.
    /// - `storeKitTransactionId` is duplicated into `canonicalJoinTransactionId`
    ///   for purchase success / already-entitled events.
    /// - nil optionals are omitted.
    static func mapToAnalyticsPayload(_ event: HeliumEvent) -> [String: Any] {
        var payload: [String: Any] = ["type": getEventName(event)]

        switch event {
        // MARK: Lifecycle events
        case let e as PaywallOpenEvent:
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
            payload["viewType"] = e.viewType.rawValue
            payload["loadTimeTakenMS"] = e.loadTimeTakenMS
            payload["loadingBudgetMS"] = e.loadingBudgetMS
            payload["paywallUnavailableReason"] = e.paywallUnavailableReason?.rawValue
            payload["newWindowCreated"] = e.newWindowCreated
        case let e as PaywallOpenFailedEvent:
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
            payload["errorDescription"] = e.error
            payload["paywallUnavailableReason"] = e.paywallUnavailableReason?.rawValue
            payload["loadTimeTakenMS"] = e.loadTimeTakenMS
            payload["loadingBudgetMS"] = e.loadingBudgetMS
            payload["newWindowCreated"] = e.newWindowCreated
        case let e as PaywallCloseEvent:
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
        case let e as PaywallDismissedEvent:
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
            payload["dismissAll"] = e.dismissAll
        case let e as PaywallSkippedEvent:
            payload["triggerName"] = e.triggerName
            payload["skipReason"] = e.skipReason.rawValue
        case let e as PaywallWebViewRenderedEvent:
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
            payload["webviewRenderTimeTakenMS"] = e.webviewRenderTimeTakenMS
            payload["paywallUnavailableReason"] = e.paywallUnavailableReason?.rawValue
        case let e as PaywallButtonPressedEvent:
            payload["ctaName"] = e.buttonName
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
        case let e as CustomPaywallActionEvent:
            payload["actionName"] = e.actionName
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
            if JSONSerialization.isValidJSONObject(e.params),
               let jsonData = try? JSONSerialization.data(withJSONObject: e.params),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                payload["params"] = jsonString
            }

        // MARK: Purchase events
        case let e as ProductSelectedEvent:
            payload["productKey"] = e.productId
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
        case let e as PurchasePressedEvent:
            payload["productKey"] = e.productId
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
            payload["paymentProcessor"] = e.paymentProcessor.rawValue
        case let e as PurchaseCancelledEvent:
            payload["productKey"] = e.productId
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
            payload["paymentProcessor"] = e.paymentProcessor.rawValue
        case let e as PurchaseSucceededEvent:
            payload["productKey"] = e.productId
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
            payload["storeKitTransactionId"] = e.storeKitTransactionId
            payload["storeKitOriginalTransactionId"] = e.storeKitOriginalTransactionId
            payload["skPostPurchaseTxnTimeMS"] = e.skPostPurchaseTxnTimeMS
            payload["canonicalJoinTransactionId"] = e.storeKitTransactionId
            payload["paymentProcessor"] = e.paymentProcessor.rawValue
        case let e as PurchaseFailedEvent:
            payload["productKey"] = e.productId
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
            payload["errorDescription"] = e.error?.localizedDescription
            payload["paymentProcessor"] = e.paymentProcessor.rawValue
        case let e as PurchaseRestoredEvent:
            // paymentProcessor intentionally not sent — the legacy wire format
            // for subscriptionRestored never carried it.
            payload["productKey"] = e.productId
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
            payload["restoreOrigin"] = e.restoreOrigin.rawValue
        case let e as PurchaseRestoreFailedEvent:
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
        case let e as PurchaseAlreadyEntitledEvent:
            payload["productKey"] = e.productId
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName
            payload["storeKitTransactionId"] = e.storeKitTransactionId
            payload["storeKitOriginalTransactionId"] = e.storeKitOriginalTransactionId
            payload["canonicalJoinTransactionId"] = e.storeKitTransactionId
        case let e as PurchasePendingEvent:
            payload["productKey"] = e.productId
            payload["triggerName"] = e.triggerName
            payload["paywallTemplateName"] = e.paywallName

        // MARK: System events
        case is InitializeCalledEvent:
            break
        case let e as PaywallsDownloadSuccessEvent:
            payload["downloadTimeTakenMS"] = e.downloadTimeTakenMS
            payload["imagesDownloadTimeTakenMS"] = e.imagesDownloadTimeTakenMS
            payload["fontsDownloadTimeTakenMS"] = e.fontsDownloadTimeTakenMS
            payload["bundleDownloadTimeMS"] = e.bundleDownloadTimeMS
            payload["localizedPriceTimeMS"] = e.localizedPriceTimeMS
            payload["localizedPriceSuccess"] = e.localizedPriceSuccess
            payload["numBundles"] = e.numBundles
            payload["numBundlesFromCache"] = e.numBundlesFromCache
            payload["uncachedBundleSizeKB"] = e.uncachedBundleSizeKB
            payload["numAttempts"] = e.numAttempts
            payload["numBundleAttempts"] = e.numBundleAttempts
            payload["totalInitializeTimeMS"] = e.totalInitializeTimeMS
        case let e as PaywallsDownloadErrorEvent:
            payload["errorDescription"] = e.error
            payload["configDownloaded"] = e.configDownloaded
            payload["downloadTimeTakenMS"] = e.downloadTimeTakenMS
            payload["bundleDownloadTimeMS"] = e.bundleDownloadTimeMS
            payload["numBundles"] = e.numBundles
            payload["numBundlesNotDownloaded"] = e.numBundlesNotDownloaded
            payload["numAttempts"] = e.numAttempts
            payload["numBundleAttempts"] = e.numBundleAttempts
            payload["totalInitializeTimeMS"] = e.totalInitializeTimeMS
        case let e as UserAllocatedEvent:
            // experimentInfo intentionally not included — it rides top-level on
            // HeliumPaywallLoggedEvent.experimentInfo.
            payload["triggerName"] = e.trigger

        default:
            // Every event type must have an explicit case above. Degrade to a
            // type-only payload rather than dropping the event or crashing.
            HeliumLogger.log(.error, category: .events, "No analytics payload mapping for event", metadata: ["event": event.eventName])
        }

        return payload
    }

    /// Analytics event name for an event — the `type` discriminator and the
    /// suffix of the `helium_`-prefixed track name. Purchase events use legacy
    /// subscription-era names that differ from `eventName`.
    static func getEventName(_ event: HeliumEvent) -> String {
        switch event {
        case is PaywallButtonPressedEvent: return "ctaPressed"
        case is ProductSelectedEvent: return "offerSelected"
        case is PurchasePressedEvent: return "subscriptionPressed"
        case is PurchaseCancelledEvent: return "subscriptionCancelled"
        case is PurchaseSucceededEvent: return "subscriptionSucceeded"
        case is PurchaseFailedEvent: return "subscriptionFailed"
        case is PurchaseRestoredEvent: return "subscriptionRestored"
        case is PurchaseRestoreFailedEvent: return "subscriptionRestoreFailed"
        case is PurchasePendingEvent: return "subscriptionPending"
        case is PurchaseAlreadyEntitledEvent: return "purchase_already_entitled"
        default: return event.eventName
        }
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
