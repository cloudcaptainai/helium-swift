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
                paywallUnavailableReason: .notInitialized, newWindowCreated: true
            ),
            equals: [
                "type": "paywallOpen",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "viewType": "presented",
                "loadTimeTakenMS": 123,
                "loadingBudgetMS": 500,
                "paywallUnavailableReason": "notInitialized",
                "newWindowCreated": true,
            ]
        )
        try assertWirePayload(
            PaywallOpenEvent(triggerName: "onboarding", paywallName: "spring_sale", viewType: .embedded),
            equals: [
                "type": "paywallOpen",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "viewType": "embedded",
            ]
        )
    }

    func testPaywallOpenFailedPayload() throws {
        try assertWirePayload(
            PaywallOpenFailedEvent(
                triggerName: "onboarding", paywallName: "spring_sale", error: "WebView failed to load",
                paywallUnavailableReason: .paywallsNotDownloaded,
                loadTimeTakenMS: 3000, loadingBudgetMS: 2000, newWindowCreated: false
            ),
            equals: [
                "type": "paywallOpenFailed",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "errorDescription": "WebView failed to load",
                "paywallUnavailableReason": "paywallsNotDownloaded",
                "loadTimeTakenMS": 3000,
                "loadingBudgetMS": 2000,
                "newWindowCreated": false,
            ]
        )
        try assertWirePayload(
            PaywallOpenFailedEvent(triggerName: "onboarding", paywallName: "", error: "Template not found"),
            equals: [
                "type": "paywallOpenFailed",
                "triggerName": "onboarding",
                "paywallTemplateName": "",
                "errorDescription": "Template not found",
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
            ]
        )
    }

    func testPaywallDismissedPayload() throws {
        try assertWirePayload(
            PaywallDismissedEvent(triggerName: "onboarding", paywallName: "spring_sale", dismissAll: true),
            equals: [
                "type": "paywallDismissed",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "dismissAll": true,
            ]
        )
        try assertWirePayload(
            PaywallDismissedEvent(triggerName: "onboarding", paywallName: "spring_sale"),
            equals: [
                "type": "paywallDismissed",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
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
                webviewRenderTimeTakenMS: 250, paywallUnavailableReason: .triggerHasNoPaywall
            ),
            equals: [
                "type": "paywallWebViewRendered",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "webviewRenderTimeTakenMS": 250,
                "paywallUnavailableReason": "triggerHasNoPaywall",
            ]
        )
        try assertWirePayload(
            PaywallWebViewRenderedEvent(triggerName: "onboarding", paywallName: "spring_sale"),
            equals: [
                "type": "paywallWebViewRendered",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
            ]
        )
    }

    func testPaywallButtonPressedPayload() throws {
        try assertWirePayload(
            PaywallButtonPressedEvent(buttonName: "learn_more", triggerName: "onboarding", paywallName: "spring_sale"),
            equals: [
                "type": "ctaPressed",
                "ctaName": "learn_more",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
            ]
        )
    }

    func testCustomPaywallActionPayload() throws {
        // params is JSON-stringified on the wire; assertWirePayload compares it parsed.
        try assertWirePayload(
            CustomPaywallActionEvent(
                actionName: "toggle_feature",
                params: ["count": 2, "flag": true, "name": "abc"],
                triggerName: "onboarding", paywallName: "spring_sale"
            ),
            equals: [
                "type": "customPaywallAction",
                "actionName": "toggle_feature",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "params": ["count": 2, "flag": true, "name": "abc"],
            ]
        )
        let payload = try mapperPayload(for: CustomPaywallActionEvent(
            actionName: "noop", params: [:], triggerName: "onboarding", paywallName: "spring_sale"
        ))
        XCTAssertEqual(payload["params"] as? String, "{}")
    }

    // MARK: - Purchase events

    func testProductSelectedPayload() throws {
        try assertWirePayload(
            ProductSelectedEvent(productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale"),
            equals: [
                "type": "offerSelected",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
            ]
        )
    }

    func testPurchasePressedPayload() throws {
        try assertWirePayload(
            PurchasePressedEvent(productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale", paymentProcessor: .appStore),
            equals: [
                "type": "subscriptionPressed",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "paymentProcessor": "appStore",
            ]
        )
    }

    func testPurchaseCancelledPayload() throws {
        try assertWirePayload(
            PurchaseCancelledEvent(productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale", paymentProcessor: .stripe),
            equals: [
                "type": "subscriptionCancelled",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "paymentProcessor": "stripe",
            ]
        )
    }

    func testPurchaseSucceededPayload() throws {
        try assertWirePayload(
            PurchaseSucceededEvent(
                productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale",
                storeKitTransactionId: "txn_123", storeKitOriginalTransactionId: "txn_001",
                skPostPurchaseTxnTimeMS: 88, paymentProcessor: .appStore
            ),
            equals: [
                "type": "subscriptionSucceeded",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
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
                storeKitTransactionId: nil, storeKitOriginalTransactionId: nil, paymentProcessor: .paddle
            ),
            equals: [
                "type": "subscriptionSucceeded",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "paymentProcessor": "paddle",
            ]
        )
    }

    func testPurchaseFailedPayload() throws {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Something failed"])
        try assertWirePayload(
            PurchaseFailedEvent(productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale", error: error, paymentProcessor: .paddle),
            equals: [
                "type": "subscriptionFailed",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "errorDescription": "Something failed",
                "paymentProcessor": "paddle",
            ]
        )
        try assertWirePayload(
            PurchaseFailedEvent(productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale", paymentProcessor: .appStore),
            equals: [
                "type": "subscriptionFailed",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "paymentProcessor": "appStore",
            ]
        )
    }

    func testPurchaseRestoredPayload() throws {
        // The subscriptionRestored wire format does not carry paymentProcessor.
        try assertWirePayload(
            PurchaseRestoredEvent(
                productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale",
                restoreOrigin: .restorePurchases, paymentProcessor: .appStore
            ),
            equals: [
                "type": "subscriptionRestored",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "restoreOrigin": "restorePurchases",
            ]
        )
    }

    func testPurchaseRestoreFailedPayload() throws {
        try assertWirePayload(
            PurchaseRestoreFailedEvent(triggerName: "onboarding", paywallName: "spring_sale"),
            equals: [
                "type": "subscriptionRestoreFailed",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
            ]
        )
    }

    func testPurchaseAlreadyEntitledPayload() throws {
        try assertWirePayload(
            PurchaseAlreadyEntitledEvent(
                productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale",
                storeKitTransactionId: "txn_123", storeKitOriginalTransactionId: "txn_001"
            ),
            equals: [
                "type": "purchase_already_entitled",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
                "storeKitTransactionId": "txn_123",
                "storeKitOriginalTransactionId": "txn_001",
                "canonicalJoinTransactionId": "txn_123",
            ]
        )
        try assertWirePayload(
            PurchaseAlreadyEntitledEvent(
                productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale",
                storeKitTransactionId: nil, storeKitOriginalTransactionId: nil
            ),
            equals: [
                "type": "purchase_already_entitled",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
            ]
        )
    }

    func testPurchasePendingPayload() throws {
        // The subscriptionPending wire format does not carry paymentProcessor.
        try assertWirePayload(
            PurchasePendingEvent(productId: "com.test.product", triggerName: "onboarding", paywallName: "spring_sale", paymentProcessor: .appStore),
            equals: [
                "type": "subscriptionPending",
                "productKey": "com.test.product",
                "triggerName": "onboarding",
                "paywallTemplateName": "spring_sale",
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
            (PaywallOpenEvent(triggerName: "t", paywallName: "p", viewType: .triggered), "helium_paywallOpen"),
            (PaywallOpenFailedEvent(triggerName: "t", paywallName: "p", error: "e"), "helium_paywallOpenFailed"),
            (PaywallCloseEvent(triggerName: "t", paywallName: "p"), "helium_paywallClose"),
            (PaywallDismissedEvent(triggerName: "t", paywallName: "p"), "helium_paywallDismissed"),
            (PaywallSkippedEvent(triggerName: "t"), "helium_paywallSkipped"),
            (PaywallWebViewRenderedEvent(triggerName: "t", paywallName: "p"), "helium_paywallWebViewRendered"),
            (PaywallButtonPressedEvent(buttonName: "b", triggerName: "t", paywallName: "p"), "helium_ctaPressed"),
            (CustomPaywallActionEvent(actionName: "a", params: [:], triggerName: "t", paywallName: "p"), "helium_customPaywallAction"),
            (ProductSelectedEvent(productId: "pr", triggerName: "t", paywallName: "p"), "helium_offerSelected"),
            (PurchasePressedEvent(productId: "pr", triggerName: "t", paywallName: "p", paymentProcessor: .appStore), "helium_subscriptionPressed"),
            (PurchaseCancelledEvent(productId: "pr", triggerName: "t", paywallName: "p", paymentProcessor: .appStore), "helium_subscriptionCancelled"),
            (PurchaseSucceededEvent(productId: "pr", triggerName: "t", paywallName: "p", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil), "helium_subscriptionSucceeded"),
            (PurchaseFailedEvent(productId: "pr", triggerName: "t", paywallName: "p", paymentProcessor: .appStore), "helium_subscriptionFailed"),
            (PurchaseRestoredEvent(productId: "pr", triggerName: "t", paywallName: "p", restoreOrigin: .duringPurchase, paymentProcessor: .appStore), "helium_subscriptionRestored"),
            (PurchaseRestoreFailedEvent(triggerName: "t", paywallName: "p"), "helium_subscriptionRestoreFailed"),
            (PurchaseAlreadyEntitledEvent(productId: "pr", triggerName: "t", paywallName: "p", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil), "helium_purchase_already_entitled"),
            (PurchasePendingEvent(productId: "pr", triggerName: "t", paywallName: "p", paymentProcessor: .appStore), "helium_subscriptionPending"),
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
            PaywallOpenEvent(triggerName: "trig", paywallName: "tmpl", viewType: .presented),
            PaywallOpenFailedEvent(triggerName: "trig", paywallName: "tmpl", error: "e"),
            PaywallCloseEvent(triggerName: "trig", paywallName: "tmpl"),
            PaywallDismissedEvent(triggerName: "trig", paywallName: "tmpl"),
            PaywallWebViewRenderedEvent(triggerName: "trig", paywallName: "tmpl"),
            PaywallButtonPressedEvent(buttonName: "b", triggerName: "trig", paywallName: "tmpl"),
            CustomPaywallActionEvent(actionName: "a", params: [:], triggerName: "trig", paywallName: "tmpl"),
            ProductSelectedEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl"),
            PurchasePressedEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", paymentProcessor: .appStore),
            PurchaseCancelledEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", paymentProcessor: .appStore),
            PurchaseSucceededEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil),
            PurchaseFailedEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", paymentProcessor: .appStore),
            PurchaseRestoredEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", restoreOrigin: .restorePurchases, paymentProcessor: .appStore),
            PurchaseRestoreFailedEvent(triggerName: "trig", paywallName: "tmpl"),
            PurchaseAlreadyEntitledEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil),
            PurchasePendingEvent(productId: "pr", triggerName: "trig", paywallName: "tmpl", paymentProcessor: .appStore),
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
        let event = PaywallCloseEvent(triggerName: "onboarding", paywallName: "spring_sale")
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
        ])
        XCTAssertEqual(encoded["isHeliumEvent"] as? Bool, true)
        XCTAssertEqual(encoded["userId"] as? String, "user_1")
    }
}
