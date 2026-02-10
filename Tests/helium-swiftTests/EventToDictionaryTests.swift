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
        XCTAssertEqual(dict["skipReason"] as? PaywallSkippedReason, .targetingHoldout)
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
            PurchaseCancelledEvent(productId: "prod", triggerName: "t", paywallName: "p"),
            PurchaseFailedEvent(productId: "prod", triggerName: "t", paywallName: "p"),
            PurchaseRestoredEvent(productId: "prod", triggerName: "t", paywallName: "p"),
            PurchaseRestoreFailedEvent(triggerName: "t", paywallName: "p"),
            PurchaseAlreadyEntitledEvent(productId: "prod", triggerName: "t", paywallName: "p", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil),
            PurchasePendingEvent(productId: "prod", triggerName: "t", paywallName: "p"),
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
