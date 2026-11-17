import XCTest
@testable import Helium

/// Locks down the analytics wire format: the payload nested under the
/// `heliumEvent` key of `HeliumPaywallLoggedEvent` and the `helium_`-prefixed
/// track-event names.
///
/// Each golden test asserts the exact payload against a hardcoded expectation —
/// the regression net for the analytics wire format. Do not change the
/// expectations without a backend migration.
final class AnalyticsPayloadMappingTests: XCTestCase {

    // MARK: - Helpers

    /// Payload round-tripped through SegmentJSON + JSONEncoder — i.e. exactly
    /// what goes on the wire.
    private func mapperPayload(for event: HeliumEvent) throws -> NSDictionary {
        let json = try SegmentJSON(HeliumAnalyticsMapper.mapToAnalyticsPayload(event))
        let data = try JSONEncoder().encode(json)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    /// Replaces a JSON-stringified `params` value with its parsed dictionary so
    /// payloads can be compared without depending on key-serialization order.
    private func parsingParams(_ payload: NSDictionary) throws -> NSDictionary {
        guard let paramsString = payload["params"] as? String else { return payload }
        let parsed = try JSONSerialization.jsonObject(with: Data(paramsString.utf8))
        let copy = try XCTUnwrap(payload.mutableCopy() as? NSMutableDictionary)
        copy["params"] = parsed
        return copy
    }

    /// Asserts the exact wire payload for an event.
    private func assertWirePayload(
        _ event: HeliumEvent,
        equals expected: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try parsingParams(mapperPayload(for: event)), NSDictionary(dictionary: expected),
            "mapper payload mismatch for \(event.eventName)", file: file, line: line
        )
    }

    private func placeholderExperimentInfo() -> ExperimentInfo {
        ExperimentInfo(
            enrolledTrigger: nil, triggers: nil, experimentName: nil, experimentId: nil,
            experimentType: nil, experimentVersionId: nil, experimentMetadata: nil,
            startDate: nil, endDate: nil, audienceId: nil, audienceData: nil as AnyCodable?,
            chosenVariantDetails: nil, hashDetails: nil
        )
    }

    // MARK: - Lifecycle events

    func testPaywallOpenPayload() throws {
        try assertWirePayload(
            PaywallOpenEvent(
                triggerName: "onboarding", paywallName: "spring_sale", viewType: .presented,
                loadTimeTakenMS: 123, loadingBudgetMS: 500,
                paywallUnavailableReason: .notInitialized, newWindowCreated: true, secondTry: false
            ),
            equals: [
                "type": "paywallOpen",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "viewType": "presented",
                "loadTimeTakenMS": 123,
                "loadingBudgetMS": 500,
                "paywallUnavailableReason": "notInitialized",
                "newWindowCreated": true,
            ]
        )
        try assertWirePayload(
            PaywallOpenEvent(triggerName: "onboarding", paywallName: "spring_sale", viewType: .embedded, secondTry: false),
            equals: [
                "type": "paywallOpen",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "viewType": "embedded",
            ]
        )
    }

    func testPaywallOpenFailedPayload() throws {
        try assertWirePayload(
            PaywallOpenFailedEvent(
                triggerName: "onboarding", paywallName: "spring_sale", error: "WebView failed to load",
                paywallUnavailableReason: .paywallsNotDownloaded,
                loadTimeTakenMS: 3000, loadingBudgetMS: 2000, newWindowCreated: false, secondTry: false
            ),
            equals: [
                "type": "paywallOpenFailed",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "errorDescription": "WebView failed to load",
                "paywallUnavailableReason": "paywallsNotDownloaded",
                "loadTimeTakenMS": 3000,
                "loadingBudgetMS": 2000,
                "newWindowCreated": false,
            ]
        )
        try assertWirePayload(
            PaywallOpenFailedEvent(triggerName: "onboarding", paywallName: "", error: "Template not found", secondTry: false),
            equals: [
                "type": "paywallOpenFailed",
                "triggerName": "onboarding",
                "paywallTemplateName": "",
                "isSecondTry": false,
                "errorDescription": "Template not found",
            ]
        )
    }

    func testBanditReasonCodeIsSentAsFailureClassWhenTriggerHasNoPaywall() throws {
        defer { HeliumFetchedConfigManager.reset() }
        var config = makeTestConfig(triggers: [:])
        config.triggerToPaywallReasons = [
            "onboarding": BanditTriggerReason(
                code: "paddle_geo_blocked",
                message: "App-to-Web paywalls are not available in this region."
            ),
        ]
        injectConfig(config)

        try assertWirePayload(
            PaywallOpenFailedEvent(
                triggerName: "onboarding", paywallName: "", error: "No paywall for trigger",
                paywallUnavailableReason: .triggerHasNoPaywall, secondTry: false
            ),
            equals: [
                "type": "paywallOpenFailed",
                "triggerName": "onboarding",
                "paywallTemplateName": "",
                "isSecondTry": false,
                "errorDescription": "No paywall for trigger",
                "paywallUnavailableReason": "triggerHasNoPaywall",
                "failureClass": "paddle_geo_blocked",
            ]
        )
        try assertWirePayload(
            PaywallOpenEvent(
                triggerName: "onboarding", paywallName: "fallback_onboarding", viewType: .presented,
                paywallUnavailableReason: .triggerHasNoPaywall, secondTry: false
            ),
            equals: [
                "type": "paywallOpen",
                "triggerName": "onboarding",
                "paywallTemplateName": "fallback_onboarding",
                "isSecondTry": false,
                "viewType": "presented",
                "paywallUnavailableReason": "triggerHasNoPaywall",
                "failureClass": "paddle_geo_blocked",
            ]
        )
        // Bandit's code only explains a missing paywall, not an SDK-side failure on the same trigger.
        try assertWirePayload(
            PaywallOpenFailedEvent(
                triggerName: "onboarding", paywallName: "", error: "A paywall is already being presented.",
                paywallUnavailableReason: .alreadyPresented, secondTry: false
            ),
            equals: [
                "type": "paywallOpenFailed",
                "triggerName": "onboarding",
                "paywallTemplateName": "",
                "isSecondTry": false,
                "errorDescription": "A paywall is already being presented.",
                "paywallUnavailableReason": "alreadyPresented",
            ]
        )
    }

    func testPaywallClosePayload() throws {
        try assertWirePayload(
            PaywallCloseEvent(triggerName: "onboarding", paywallName: "spring_sale", secondTry: true),
            equals: [
                "type": "paywallClose",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": true,
            ]
        )
    }

    func testSecondTryFailureAndPurchasePayloads() throws {
        try assertWirePayload(
            PaywallOpenFailedEvent(triggerName: "retry", paywallName: "Second", error: "Unable to open", secondTry: true),
            equals: [
                "type": "paywallOpenFailed",
                "triggerName": "retry",
                "paywallTemplateName": "Second",
                "isSecondTry": true,
                "errorDescription": "Unable to open",
            ]
        )
        let purchase = PurchaseSucceededEvent(
            productId: "prod_b:price_b", triggerName: "onboarding", paywallName: "Second",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil, paymentProcessor: .stripe, secondTry: true
        )
        try assertWirePayload(purchase, equals: [
            "type": "subscriptionSucceeded",
            "triggerName": "onboarding",
            "paywallTemplateName": "Second",
            "isSecondTry": true,
            "productKey": "prod_b:price_b",
            "paymentProcessor": "stripe",
        ])
    }

    func testPaywallDismissedPayload() throws {
        try assertWirePayload(
            PaywallDismissedEvent(triggerName: "onboarding", paywallName: "spring_sale", dismissAll: true, secondTry: false),
            equals: [
                "type": "paywallDismissed",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "dismissAll": true,
            ]
        )
        try assertWirePayload(
            PaywallDismissedEvent(triggerName: "onboarding", paywallName: "spring_sale", secondTry: false),
            equals: [
                "type": "paywallDismissed",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "dismissAll": false,
            ]
        )
    }

    func testPaywallSkippedPayload() throws {
        try assertWirePayload(
            PaywallSkippedEvent(triggerName: "onboarding", skipReason: .alreadyEntitled),
            equals: [
                "type": "paywallSkipped",
                "triggerName": "onboarding",
                "skipReason": "alreadyEntitled",
            ]
        )
    }

    func testPaywallWebViewRenderedPayload() throws {
        try assertWirePayload(
            PaywallWebViewRenderedEvent(
                triggerName: "onboarding", paywallName: "spring_sale",
                webviewRenderTimeTakenMS: 250, paywallUnavailableReason: .triggerHasNoPaywall, secondTry: false
            ),
            equals: [
                "type": "paywallWebViewRendered",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "webviewRenderTimeTakenMS": 250,
                "paywallUnavailableReason": "triggerHasNoPaywall",
            ]
        )
        try assertWirePayload(
            PaywallWebViewRenderedEvent(triggerName: "onboarding", paywallName: "spring_sale", secondTry: false),
            equals: [
                "type": "paywallWebViewRendered",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
            ]
        )
    }

    func testPaywallButtonPressedPayload() throws {
        try assertWirePayload(
            PaywallButtonPressedEvent(buttonName: "learn_more", triggerName: "onboarding", paywallName: "spring_sale", secondTry: false),
            equals: [
                "type": "ctaPressed",
                "ctaName": "learn_more",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
            ]
        )
    }

    func testCustomPaywallActionPayload() throws {
        // params is JSON-stringified on the wire; assertWirePayload compares it parsed.
        try assertWirePayload(
            CustomPaywallActionEvent(
                actionName: "toggle_feature",
                params: ["count": 2, "flag": true, "name": "abc"],
                triggerName: "onboarding", paywallName: "spring_sale", secondTry: false
            ),
            equals: [
                "type": "customPaywallAction",
                "actionName": "toggle_feature",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "params": ["count": 2, "flag": true, "name": "abc"],
            ]
        )
        let payload = try mapperPayload(for: CustomPaywallActionEvent(
            actionName: "noop", params: [:], triggerName: "onboarding", paywallName: "spring_sale", secondTry: false
        ))
        XCTAssertEqual(payload["params"] as? String, "{}")
    }

    // MARK: - Purchase events

    func testProductSelectedPayload() throws {
        try assertWirePayload(
            ProductSelectedEvent(productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale", secondTry: false),
            equals: [
                "type": "offerSelected",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
            ]
        )
    }

    func testPurchasePressedPayload() throws {
        try assertWirePayload(
            PurchasePressedEvent(productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale", paymentProcessor: .appStore, secondTry: false),
            equals: [
                "type": "subscriptionPressed",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "paymentProcessor": "appStore",
            ]
        )
    }

    func testPurchaseCancelledPayload() throws {
        try assertWirePayload(
            PurchaseCancelledEvent(productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale", paymentProcessor: .stripe, secondTry: false),
            equals: [
                "type": "subscriptionCancelled",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "paymentProcessor": "stripe",
            ]
        )
    }

    func testPurchaseSucceededPayload() throws {
        try assertWirePayload(
            PurchaseSucceededEvent(
                productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale",
                storeKitTransactionId: "txn_123", storeKitOriginalTransactionId: "txn_001",
                skPostPurchaseTxnTimeMS: 88, paymentProcessor: .appStore, secondTry: false
            ),
            equals: [
                "type": "subscriptionSucceeded",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "storeKitTransactionId": "txn_123",
                "storeKitOriginalTransactionId": "txn_001",
                "skPostPurchaseTxnTimeMS": 88,
                "canonicalJoinTransactionId": "txn_123",
                "paymentProcessor": "appStore",
            ]
        )
        try assertWirePayload(
            PurchaseSucceededEvent(
                productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale",
                storeKitTransactionId: nil, storeKitOriginalTransactionId: nil, paymentProcessor: .paddle, secondTry: false
            ),
            equals: [
                "type": "subscriptionSucceeded",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "paymentProcessor": "paddle",
            ]
        )
    }

    func testPurchaseSucceededPayloadIncludesOfferIdentifier() throws {
        try assertWirePayload(
            PurchaseSucceededEvent(
                productId: "com.test.product", offerIdentifier: "WIN_BACK",
                triggerName: "onboarding", paywallName: "spring_sale",
                storeKitTransactionId: nil, storeKitOriginalTransactionId: nil,
                paymentProcessor: .appStore, secondTry: false
            ),
            equals: [
                "type": "subscriptionSucceeded",
                "productKey": "com.test.product",
                "offerIdentifier": "WIN_BACK",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "paymentProcessor": "appStore",
            ]
        )
        try assertWirePayload(
            PurchaseSucceededEvent(
                productId: "com.test.product",
                triggerName: "onboarding", paywallName: "spring_sale",
                storeKitTransactionId: nil, storeKitOriginalTransactionId: nil,
                paymentProcessor: .appStore, secondTry: false
            ),
            equals: [
                "type": "subscriptionSucceeded",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "paymentProcessor": "appStore",
            ]
        )
    }

    func testPurchaseFailedPayload() throws {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Something failed"])
        try assertWirePayload(
            PurchaseFailedEvent(productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale", error: error, paymentProcessor: .paddle, secondTry: false),
            equals: [
                "type": "subscriptionFailed",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "errorDescription": "Something failed",
                "paymentProcessor": "paddle",
            ]
        )
        try assertWirePayload(
            PurchaseFailedEvent(productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale", paymentProcessor: .appStore, secondTry: false),
            equals: [
                "type": "subscriptionFailed",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "paymentProcessor": "appStore",
            ]
        )
    }

    func testPurchaseRestoredPayload() throws {
        try assertWirePayload(
            PurchaseRestoredEvent(
                productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale",
                restoreOrigin: .restorePurchases, paymentProcessor: .paddle, secondTry: false
            ),
            equals: [
                "type": "subscriptionRestored",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "restoreOrigin": "restorePurchases",
                "paymentProcessor": "paddle",
            ]
        )
    }

    func testPurchaseRestoreFailedPayload() throws {
        try assertWirePayload(
            PurchaseRestoreFailedEvent(triggerName: "onboarding", paywallName: "spring_sale", secondTry: false),
            equals: [
                "type": "subscriptionRestoreFailed",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
            ]
        )
    }

    func testPurchaseAlreadyEntitledPayload() throws {
        try assertWirePayload(
            PurchaseAlreadyEntitledEvent(
                productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale",
                storeKitTransactionId: "txn_123", storeKitOriginalTransactionId: "txn_001", secondTry: false
            ),
            equals: [
                "type": "purchase_already_entitled",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "storeKitTransactionId": "txn_123",
                "storeKitOriginalTransactionId": "txn_001",
                "canonicalJoinTransactionId": "txn_123",
            ]
        )
        try assertWirePayload(
            PurchaseAlreadyEntitledEvent(
                productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale",
                storeKitTransactionId: nil, storeKitOriginalTransactionId: nil, secondTry: false
            ),
            equals: [
                "type": "purchase_already_entitled",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
            ]
        )
    }

    func testPurchasePendingPayload() throws {
        try assertWirePayload(
            PurchasePendingEvent(productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale", paymentProcessor: .appStore, secondTry: false),
            equals: [
                "type": "subscriptionPending",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "isSecondTry": false,
                "paymentProcessor": "appStore",
            ]
        )
    }

    // MARK: - System events

    func testInitializeCalledPayload() throws {
        try assertWirePayload(InitializeCalledEvent(), equals: ["type": "initializeCalled"])
    }

    func testPaywallsDownloadSuccessPayload() throws {
        let fullEvent = PaywallsDownloadSuccessEvent(
            downloadTimeTakenMS: 100, imagesDownloadTimeTakenMS: 200, fontsDownloadTimeTakenMS: 300,
            bundleDownloadTimeMS: 400, localizedPriceTimeMS: 500, localizedPriceSuccess: true,
            numBundles: 3, numBundlesFromCache: 1, uncachedBundleSizeKB: 512,
            numAttempts: 1, numBundleAttempts: 2, totalInitializeTimeMS: 900
        )
        let expected: NSDictionary = [
            "type": "paywallsDownloadSuccess",
            "downloadTimeTakenMS": 100,
            "imagesDownloadTimeTakenMS": 200,
            "fontsDownloadTimeTakenMS": 300,
            "bundleDownloadTimeMS": 400,
            "localizedPriceTimeMS": 500,
            "localizedPriceSuccess": true,
            "numBundles": 3,
            "numBundlesFromCache": 1,
            "uncachedBundleSizeKB": 512,
            "numAttempts": 1,
            "numBundleAttempts": 2,
            "totalInitializeTimeMS": 900,
        ]

        // configId is intentionally absent; the real config id is sent
        // top-level as HeliumPaywallLoggedEvent.fetchedConfigId.
        XCTAssertEqual(try mapperPayload(for: fullEvent), expected)
        XCTAssertEqual(try mapperPayload(for: PaywallsDownloadSuccessEvent()),
                       ["type": "paywallsDownloadSuccess"])
    }

    func testPaywallsDownloadErrorPayload() throws {
        try assertWirePayload(
            PaywallsDownloadErrorEvent(
                error: "Network timeout", configDownloaded: false,
                downloadTimeTakenMS: 100, bundleDownloadTimeMS: 200,
                numBundles: 3, numBundlesNotDownloaded: 2,
                numAttempts: 4, numBundleAttempts: 5, totalInitializeTimeMS: 600
            ),
            equals: [
                "type": "paywallsDownloadError",
                "errorDescription": "Network timeout",
                "configDownloaded": false,
                "downloadTimeTakenMS": 100,
                "bundleDownloadTimeMS": 200,
                "numBundles": 3,
                "numBundlesNotDownloaded": 2,
                "numAttempts": 4,
                "numBundleAttempts": 5,
                "totalInitializeTimeMS": 600,
            ]
        )
        try assertWirePayload(
            PaywallsDownloadErrorEvent(error: "Network timeout", configDownloaded: true),
            equals: [
                "type": "paywallsDownloadError",
                "errorDescription": "Network timeout",
                "configDownloaded": true,
            ]
        )
    }

    func testUserAllocatedPayload() throws {
        // experimentInfo is intentionally not part of this payload — it rides
        // top-level on HeliumPaywallLoggedEvent.experimentInfo.
        try assertWirePayload(
            UserAllocatedEvent(trigger: "onboarding", experimentInfo: placeholderExperimentInfo()),
            equals: [
                "type": "userAllocated",
                "triggerName": "onboarding",
            ]
        )
    }

    // MARK: - Track-event names

    func testTrackEventNames() throws {
        let samples: [(HeliumEvent, String)] = [
            (InitializeCalledEvent(), "helium_initializeCalled"),
            (PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .triggered, secondTry: false), "helium_paywallOpen"),
            (PaywallOpenFailedEvent(triggerName: "t", paywallName: "p", error: "e", secondTry: false), "helium_paywallOpenFailed"),
            (PaywallCloseEvent(triggerName: "t", paywallName: "p", secondTry: false), "helium_paywallClose"),
            (PaywallDismissedEvent(triggerName: "t", paywallName: "p", secondTry: false), "helium_paywallDismissed"),
            (PaywallSkippedEvent(triggerName: "t"), "helium_paywallSkipped"),
            (PaywallWebViewRenderedEvent(triggerName: "t", paywallName: "p", secondTry: false), "helium_paywallWebViewRendered"),
            (PaywallButtonPressedEvent(buttonName: "b", triggerName: "t", paywallName: "p", secondTry: false), "helium_ctaPressed"),
            (CustomPaywallActionEvent(actionName: "a", params: [:], triggerName: "t", paywallName: "p", secondTry: false), "helium_customPaywallAction"),
            (ProductSelectedEvent(productId: "pr", triggerName: "t", paywallName: "p", secondTry: false), "helium_offerSelected"),
            (PurchasePressedEvent(productId: "pr", triggerName: "t", paywallName: "p", paymentProcessor: .appStore, secondTry: false), "helium_subscriptionPressed"),
            (PurchaseCancelledEvent(productId: "pr", triggerName: "t", paywallName: "p", paymentProcessor: .appStore, secondTry: false), "helium_subscriptionCancelled"),
            (PurchaseSucceededEvent(productId: "pr", triggerName: "t", paywallName: "p", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil, secondTry: false), "helium_subscriptionSucceeded"),
            (PurchaseFailedEvent(productId: "pr", triggerName: "t", paywallName: "p", paymentProcessor: .appStore, secondTry: false), "helium_subscriptionFailed"),
            (PurchaseRestoredEvent(productId: "pr", triggerName: "t", paywallName: "p", restoreOrigin: .duringPurchase, paymentProcessor: .appStore, secondTry: false), "helium_subscriptionRestored"),
            (PurchaseRestoreFailedEvent(triggerName: "t", paywallName: "p", secondTry: false), "helium_subscriptionRestoreFailed"),
            (PurchaseAlreadyEntitledEvent(productId: "pr", triggerName: "t", paywallName: "p", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil, secondTry: false), "helium_purchase_already_entitled"),
            (PurchasePendingEvent(productId: "pr", triggerName: "t", paywallName: "p", paymentProcessor: .appStore, secondTry: false), "helium_subscriptionPending"),
            (PaywallsDownloadSuccessEvent(), "helium_paywallsDownloadSuccess"),
            (PaywallsDownloadErrorEvent(error: "e", configDownloaded: false), "helium_paywallsDownloadError"),
            (UserAllocatedEvent(trigger: "t", experimentInfo: placeholderExperimentInfo()), "helium_userAllocated"),
        ]

        for (event, expectedName) in samples {
            XCTAssertEqual("helium_" + HeliumAnalyticsMapper.getEventName(event), expectedName,
                           "mapper track name mismatch for \(event.eventName)")

            // The payload's type discriminator is always the analytics event name.
            let payload = HeliumAnalyticsMapper.mapToAnalyticsPayload(event)
            XCTAssertEqual(payload["type"] as? String,
                           HeliumAnalyticsMapper.getEventName(event),
                           "payload type mismatch for \(event.eventName)")
        }
    }

    // MARK: - Enrichment (trigger / paywall template extraction)

    func testTriggerAndTemplateExtraction() throws {
        let contextEvents: [HeliumEvent] = [
            PaywallOpenEvent(triggerName: "trig", paywallName: "tmpl", viewType: .presented, secondTry: false),
            PaywallOpenFailedEvent(triggerName: "trig", paywallName: "tmpl", error: "e", secondTry: false),
            PaywallCloseEvent(triggerName: "trig", paywallName: "tmpl", secondTry: false),
            PaywallDismissedEvent(triggerName: "trig", paywallName: "tmpl", secondTry: false),
            PaywallWebViewRenderedEvent(triggerName: "trig", paywallName: "tmpl", secondTry: false),
            PaywallButtonPressedEvent(buttonName: "b", triggerName: "trig", paywallName: "tmpl", secondTry: false),
            CustomPaywallActionEvent(actionName: "a", params: [:], triggerName: "trig", paywallName: "tmpl", secondTry: false),
            ProductSelectedEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", secondTry: false),
            PurchasePressedEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", paymentProcessor: .appStore, secondTry: false),
            PurchaseCancelledEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", paymentProcessor: .appStore, secondTry: false),
            PurchaseSucceededEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil, secondTry: false),
            PurchaseFailedEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", paymentProcessor: .appStore, secondTry: false),
            PurchaseRestoredEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", restoreOrigin: .restorePurchases, paymentProcessor: .appStore, secondTry: false),
            PurchaseRestoreFailedEvent(triggerName: "trig", paywallName: "tmpl", secondTry: false),
            PurchaseAlreadyEntitledEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil, secondTry: false),
            PurchasePendingEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", paymentProcessor: .appStore, secondTry: false),
        ]
        for event in contextEvents {
            XCTAssertEqual(HeliumAnalyticsMapper.getTriggerName(event), "trig", "\(event.eventName)")
            XCTAssertEqual(HeliumAnalyticsMapper.getPaywallTemplateName(event), "tmpl", "\(event.eventName)")
        }

        let triggerOnlyEvents: [HeliumEvent] = [
            PaywallSkippedEvent(triggerName: "trig"),
            UserAllocatedEvent(trigger: "trig", experimentInfo: placeholderExperimentInfo()),
        ]
        for event in triggerOnlyEvents {
            XCTAssertEqual(HeliumAnalyticsMapper.getTriggerName(event), "trig", "\(event.eventName)")
            XCTAssertNil(HeliumAnalyticsMapper.getPaywallTemplateName(event), "\(event.eventName)")
        }

        let contextFreeEvents: [HeliumEvent] = [
            InitializeCalledEvent(),
            PaywallsDownloadSuccessEvent(),
            PaywallsDownloadErrorEvent(error: "e", configDownloaded: false),
        ]
        for event in contextFreeEvents {
            XCTAssertNil(HeliumAnalyticsMapper.getTriggerName(event), "\(event.eventName)")
            XCTAssertNil(HeliumAnalyticsMapper.getPaywallTemplateName(event), "\(event.eventName)")
        }
    }

    // MARK: - Logged event envelope

    func testLoggedEventNestsPayloadUnderHeliumEventKey() throws {
        let event = PaywallCloseEvent(triggerName: "onboarding", paywallName: "spring_sale", secondTry: false)
        let loggedEvent = HeliumPaywallLoggedEvent(
            heliumEvent: try SegmentJSON(HeliumAnalyticsMapper.mapToAnalyticsPayload(event)),
            fetchedConfigId: nil,
            timestamp: "2026-07-14T00:00:00.000Z",
            contextTraits: nil,
            experimentID: nil,
            modelID: nil,
            paywallID: nil,
            paywallUUID: nil,
            organizationID: nil,
            heliumPersistentID: nil,
            userId: "user_1",
            heliumSessionID: nil,
            heliumInitializeId: nil,
            heliumPaywallSessionId: nil,
            appAttributionToken: nil,
            appTransactionId: nil,
            revenueCatAppUserID: nil,
            thirdPartyAnalyticsAnonymousId: nil,
            isFallback: nil,
            downloadStatus: nil,
            additionalFields: nil,
            additionalPaywallFields: nil,
            experimentInfo: nil
        )

        let data = try JSONEncoder().encode(loggedEvent)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        XCTAssertEqual(encoded["heliumEvent"] as? NSDictionary, [
            "type": "paywallClose",
            "triggerName": "onboarding",
            "paywallTemplateName": "spring_sale",
            "isSecondTry": false,
        ])
        XCTAssertEqual(encoded["isHeliumEvent"] as? Bool, true)
        XCTAssertEqual(encoded["userId"] as? String, "user_1")
    }
}
