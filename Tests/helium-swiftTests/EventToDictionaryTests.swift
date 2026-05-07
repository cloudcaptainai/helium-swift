import XCTest
@testable import Helium

final class EventToDictionaryTests: XCTestCase {

    func testPaywallOpenEventToDictionary() {
        let event = PaywallOpenEvent(
            triggerName: "onboarding",
            paywallName: "premium_wall",
            viewType: .presented,
            loadTimeTakenMS: 500,
            loadingBudgetMS: 7000,
            timestamp: Date(timeIntervalSince1970: 1000)
        )
        let dict = event.toDictionary()
        XCTAssertEqual(dict["type"] as? String, "paywallOpen")
        XCTAssertEqual(dict["triggerName"] as? String, "onboarding")
        XCTAssertEqual(dict["paywallName"] as? String, "premium_wall")
        XCTAssertEqual(dict["viewType"] as? String, "presented")
        XCTAssertEqual(dict["loadTimeTakenMS"] as? UInt64, 500)
        XCTAssertEqual(dict["loadingBudgetMS"] as? UInt64, 7000)
        XCTAssertEqual(dict["isSecondTry"] as? Bool, false)
        XCTAssertEqual(dict["timestamp"] as? Double, 1000.0)
    }

    func testPurchaseRestoredEventToDictionary_includesExistingSubscriptionIdWhenSet() {
        // Paddle web-checkout entitled-during-purchase path threads
        // existingSubscriptionId from the SDK pre-fetch's bandit 409
        // through to this event for analytics parity with the bundle's
        // helium_purchase_already_entitled fire's canonicalJoinTransactionId.
        let event = PurchaseRestoredEvent(
            productId: "pro_x:pri_y",
            triggerName: "upgrade",
            paywallName: "wall",
            restoreOrigin: .duringPurchase,
            paymentProcessor: .paddle,
            existingSubscriptionId: "sub_01k_abc"
        )
        let dict = event.toDictionary()
        XCTAssertEqual(dict["type"] as? String, "purchaseRestored")
        XCTAssertEqual(dict["existingSubscriptionId"] as? String, "sub_01k_abc")
        XCTAssertEqual(dict["restoreOrigin"] as? String, "duringPurchase")
    }

    func testPurchaseRestoredEventToDictionary_omitsExistingSubscriptionIdWhenNil() {
        // Default constructor (no sub id) — most common case (StoreKit
        // restores, cached-entitlements pre-checks). Field absent keeps
        // dashboards from confusing "missing" with "explicit null".
        let event = PurchaseRestoredEvent(
            productId: "com.app.premium",
            triggerName: "upgrade",
            paywallName: "wall",
            restoreOrigin: .restorePurchases,
            paymentProcessor: .appStore
        )
        let dict = event.toDictionary()
        XCTAssertNil(dict["existingSubscriptionId"])
    }

    func testPurchaseRestoredEventToDictionary_omitsExistingSubscriptionIdWhenEmptyString() {
        // Defensive: an empty string is logically the same as absent;
        // the toDictionary helper drops it so analytics never see an
        // empty-string id.
        let event = PurchaseRestoredEvent(
            productId: "com.app.premium",
            triggerName: "upgrade",
            paywallName: "wall",
            restoreOrigin: .duringPurchase,
            paymentProcessor: .paddle,
            existingSubscriptionId: ""
        )
        let dict = event.toDictionary()
        XCTAssertNil(dict["existingSubscriptionId"])
    }

    func testPurchaseSucceededEventToDictionary() {
        let event = PurchaseSucceededEvent(
            productId: "com.app.premium",
            triggerName: "upgrade",
            paywallName: "wall",
            storeKitTransactionId: "txn_123",
            storeKitOriginalTransactionId: "orig_456",
            skPostPurchaseTxnTimeMS: 50,
            timestamp: Date(timeIntervalSince1970: 2000)
        )
        let dict = event.toDictionary()
        XCTAssertEqual(dict["type"] as? String, "purchaseSucceeded")
        XCTAssertEqual(dict["productId"] as? String, "com.app.premium")
        XCTAssertEqual(dict["storeKitTransactionId"] as? String, "txn_123")
        XCTAssertEqual(dict["canonicalJoinTransactionId"] as? String, "txn_123")
        XCTAssertEqual(dict["storeKitOriginalTransactionId"] as? String, "orig_456")
        XCTAssertEqual(dict["skPostPurchaseTxnTimeMS"] as? UInt64, 50)
    }

    func testPaywallSkippedEventToDictionary() {
        let event = PaywallSkippedEvent(triggerName: "onboarding", skipReason: .targetingHoldout)
        let dict = event.toDictionary()
        XCTAssertEqual(dict["type"] as? String, "paywallSkipped")
        XCTAssertEqual(dict["triggerName"] as? String, "onboarding")
        XCTAssertEqual(dict["skipReason"] as? String, PaywallSkippedReason.targetingHoldout.rawValue)
    }

    func testCustomPaywallActionEventToDictionary() {
        let params: [String: Any] = ["key": "value", "count": 42]
        let event = CustomPaywallActionEvent(
            actionName: "toggle_feature",
            params: params,
            triggerName: "settings",
            paywallName: "wall"
        )
        let dict = event.toDictionary()
        XCTAssertEqual(dict["type"] as? String, "customPaywallAction")
        XCTAssertEqual(dict["actionName"] as? String, "toggle_feature")
        XCTAssertNotNil(dict["params"])
        let dictParams = dict["params"] as? [String: Any]
        XCTAssertEqual(dictParams?["key"] as? String, "value")
    }

    func testAllEventTypesHaveTypeAndTimestamp() {
        let events: [HeliumEvent] = [
            PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .presented),
            PaywallCloseEvent(triggerName: "t", paywallName: "p"),
            PaywallDismissedEvent(triggerName: "t", paywallName: "p"),
            PaywallOpenFailedEvent(triggerName: "t", paywallName: "p", error: "err"),
            PaywallSkippedEvent(triggerName: "t"),
            PaywallButtonPressedEvent(buttonName: "btn", triggerName: "t", paywallName: "p"),
            CustomPaywallActionEvent(actionName: "a", params: [:], triggerName: "t", paywallName: "p"),
            ProductSelectedEvent(productId: "prod", triggerName: "t", paywallName: "p"),
            PurchasePressedEvent(productId: "prod", triggerName: "t", paywallName: "p"),
            PurchaseSucceededEvent(productId: "prod", triggerName: "t", paywallName: "p", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil),
            PurchaseCancelledEvent(productId: "prod", triggerName: "t", paywallName: "p", paymentProcessor: .appStore),
            PurchaseFailedEvent(productId: "prod", triggerName: "t", paywallName: "p", paymentProcessor: .appStore),
            PurchaseRestoredEvent(productId: "prod", triggerName: "t", paywallName: "p", restoreOrigin: .restorePurchases, paymentProcessor: .appStore),
            PurchaseRestoreFailedEvent(triggerName: "t", paywallName: "p"),
            PurchaseAlreadyEntitledEvent(productId: "prod", triggerName: "t", paywallName: "p", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil),
            PurchasePendingEvent(productId: "prod", triggerName: "t", paywallName: "p", paymentProcessor: .appStore),
            InitializeCalledEvent(),
            PaywallsDownloadSuccessEvent(),
            PaywallsDownloadErrorEvent(error: "err", configDownloaded: false),
            PaywallWebViewRenderedEvent(triggerName: "t", paywallName: "p"),
        ]

        for event in events {
            let dict = event.toDictionary()
            XCTAssertNotNil(dict["type"], "\(type(of: event)) missing 'type'")
            XCTAssertNotNil(dict["timestamp"], "\(type(of: event)) missing 'timestamp'")
        }
    }

    func testPaywallsDownloadSuccessEventToDictionary() {
        let eventWithMetrics = PaywallsDownloadSuccessEvent(
            downloadTimeTakenMS: 1200,
            bundleDownloadTimeMS: 800,
            numBundles: 3,
            numAttempts: 2,
            totalInitializeTimeMS: 3000
        )
        let dict = eventWithMetrics.toDictionary()
        XCTAssertEqual(dict["type"] as? String, "paywallsDownloadSuccess")
        XCTAssertEqual(dict["downloadTimeTakenMS"] as? UInt64, 1200)
        XCTAssertEqual(dict["bundleDownloadTimeMS"] as? UInt64, 800)
        XCTAssertEqual(dict["numBundles"] as? Int, 3)
        XCTAssertEqual(dict["numAttempts"] as? Int, 2)
        XCTAssertEqual(dict["totalInitializeTimeMS"] as? UInt64, 3000)

        // Without optional metrics
        let eventWithoutMetrics = PaywallsDownloadSuccessEvent()
        let dictNoMetrics = eventWithoutMetrics.toDictionary()
        XCTAssertEqual(dictNoMetrics["type"] as? String, "paywallsDownloadSuccess")
        XCTAssertNil(dictNoMetrics["downloadTimeTakenMS"])
        XCTAssertNil(dictNoMetrics["bundleDownloadTimeMS"])
    }
}
