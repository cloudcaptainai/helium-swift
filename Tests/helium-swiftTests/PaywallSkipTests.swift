import XCTest
@testable import Helium

final class PaywallSkipTests: HeliumTestCase {

    override func setUp() {
        super.setUp()
        ExperimentAllocationTracker.shared.reset()
    }

    override func tearDown() {
        ExperimentAllocationTracker.shared.reset()
        super.tearDown()
    }

    private func experimentConfig(shouldShow: Bool = false) throws -> HeliumFetchedConfig {
        let fixture = #"""
        {"shouldShow":false,"experimentID":"exp-flow","paywallID":0,"paywallUUID":"synthetic-arm","paywallVersionUUID":"","paywallTemplateName":"Your paywall","productsOffered":[],"productsOfferedIOS":[],"productsOfferedAndroid":[],"productsOfferedStripe":[],"productsOfferedPaddle":[],"webProductsOfferedStripe":[],"webProductsOfferedPaddle":[],"fallbackPaywallName":"","resolvedConfig":{},"additionalPaywallFields":{},"experimentInfo":{"experimentId":"exp-flow","experimentName":"A/A","experimentType":"A/B/n test","experimentMetadata":{},"experimentVersionId":"skip-version","audienceId":"1","audienceData":"{}","chosenVariantDetails":{"allocationId":"synthetic-arm","allocationName":"Your paywall","allocationIndex":0,"allocationMetadata":{"paywall_id":"synthetic-arm","percentage":50,"variant_type":"control","variant_name":"Your paywall","show_paywall":false}},"hashDetails":{"hashedUserId":"u1","hashedUserIdBucket1To100":42,"hashMethod":"HASH_USER_ID"}}}
        """#
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        object["shouldShow"] = shouldShow
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(makeTestConfig(triggers: [:]))) as? [String: Any])
        envelope["triggerToPaywalls"] = ["checkout": object]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return try JSONDecoder().decode(HeliumFetchedConfig.self, from: data)
    }

    func testSkipArmDecodesAndAllocatesBeforeSkip() throws {
        let config = try experimentConfig()
        injectConfig(config)
        var reason: PaywallNotShownReason?
        XCTAssertTrue(HeliumPaywallPresenter.shared.skipPaywallIfNeeded(
            trigger: "checkout", presentationContext: makeTestContext(onPaywallNotShown: { reason = $0 })
        ))
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is PaywallSkippedEvent } }
        let events = mockDelegate.receivedEvents
        let allocation = try XCTUnwrap(events.first as? UserAllocatedEvent)
        XCTAssertTrue(events.last is PaywallSkippedEvent)
        XCTAssertEqual(allocation.experimentInfo.chosenVariantDetails?.allocationId, "synthetic-arm")
        XCTAssertEqual(allocation.experimentInfo.chosenVariantDetails?.allocationMetadataDictionary?["show_paywall"] as? Bool, false)
        XCTAssertEqual(reason, .targetingHoldout)
        XCTAssertFalse(events.contains { $0 is PaywallOpenEvent || $0 is PaywallOpenFailedEvent || $0 is PaywallCloseEvent })
        let logged = HeliumAnalyticsManager.shared.buildLoggedEvent(for: allocation, paywallSession: nil)
        let context = testAnalyticsDictionary(logged)["contextTraits"] as? [String: Any]
        let application = context?["applicationInfo"] as? [String: Any]
        XCTAssertEqual(application?["environment"] as? String, AppReceiptsHelper.shared.getEnvironment())
    }

    func testShowDecisionAllocatesWithoutLoadablePaywall() throws {
        injectConfig(try experimentConfig(shouldShow: true))
        HeliumPaywallPresenter.shared.presentUpsellWithLoadingBudget(trigger: "checkout", presentationContext: .empty)
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent } }
        let allocation = try XCTUnwrap(mockDelegate.receivedEvents.compactMap { $0 as? UserAllocatedEvent }.first)
        XCTAssertEqual(allocation.experimentInfo.experimentId, "exp-flow")
        XCTAssertEqual(allocation.experimentInfo.chosenVariantDetails?.allocationId, "synthetic-arm")
    }

    @MainActor
    func testPresentationConflictEnrollsBothArms() throws {
        var config = try experimentConfig(shouldShow: true)
        var skipInfo = try XCTUnwrap(config.triggerToPaywalls["checkout"])
        skipInfo.shouldShow = false
        skipInfo.experimentID = "exp-skip"
        skipInfo.experimentInfo?["experimentId"] = JSON("exp-skip")
        config.triggerToPaywalls["skip"] = skipInfo
        injectConfig(config)

        Helium.shared.presentPaywall(trigger: "already_presenting", onPaywallNotShown: { _ in })
        Helium.shared.presentPaywall(trigger: "checkout", onPaywallNotShown: { _ in })
        Helium.shared.presentPaywall(trigger: "skip", onPaywallNotShown: { _ in })
        waitForEventDispatch {
            self.mockDelegate.receivedEvents.contains { ($0 as? PaywallOpenFailedEvent)?.paywallUnavailableReason == .alreadyPresented }
                && self.mockDelegate.receivedEvents.contains { $0 is PaywallSkippedEvent }
        }
        let triggers = mockDelegate.receivedEvents.compactMap { ($0 as? UserAllocatedEvent)?.trigger }
        XCTAssertEqual(Set(triggers), Set(["checkout", "skip"]))
    }

    func testMalformedStoredEntryPreservesOtherEnrollment() throws {
        let config = try experimentConfig()
        injectConfig(config)
        let info = try XCTUnwrap(config.extractExperimentInfo(trigger: "checkout"))
        let valid = StoredAllocation(from: info, trigger: "checkout")
        var entry = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        entry["enrolledAt"] = 12345.0
        let persistentId = HeliumIdentityManager.shared.getHeliumPersistentId()
        let data = try JSONSerialization.data(withJSONObject: [
            "\(persistentId)_exp-flow": entry,
            "\(persistentId)_broken": ["allocationIndex": "not-an-index"]
        ])
        UserDefaults.standard.set(data, forKey: "heliumExperimentAllocations")
        ExperimentAllocationTracker.shared.loadStoredAllocations()
        XCTAssertEqual(config.extractExperimentInfo(trigger: "checkout")?.enrolledAt, Date(timeIntervalSinceReferenceDate: 12345))
        ExperimentAllocationTracker.shared.recordDecision(trigger: "checkout", paywallInfo: config.triggerToPaywalls["checkout"])
        drainMainActor()
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent })
    }

    func testMalformedExperimentDoesNotBlockOtherTrigger() throws {
        var config = try experimentConfig()
        var broken = try XCTUnwrap(config.triggerToPaywalls["checkout"])
        broken.experimentID = "broken"
        broken.experimentInfo = JSON(["experimentId": "broken", "hashDetails": ["hashedUserIdBucket1To100": "invalid"], "chosenVariantDetails": ["allocationMetadata": ["nested": [false, true]]]])
        config.triggerToPaywalls["broken"] = broken
        let decoded = try JSONDecoder().decode(HeliumFetchedConfig.self, from: JSONEncoder().encode(config))
        injectConfig(decoded)
        XCTAssertTrue(HeliumPaywallPresenter.shared.skipPaywallIfNeeded(trigger: "broken", presentationContext: .empty))
        XCTAssertTrue(HeliumPaywallPresenter.shared.skipPaywallIfNeeded(trigger: "checkout", presentationContext: .empty))
        waitForEventDispatch { self.mockDelegate.receivedEvents.filter { $0 is PaywallSkippedEvent }.count == 2 }
        XCTAssertEqual(mockDelegate.receivedEvents.compactMap { ($0 as? UserAllocatedEvent)?.experimentInfo.experimentId }, ["exp-flow"])
    }

    func testAllocationTriggerListUsesRemoteConfigWithFallbackLoaded() throws {
        var remote = try experimentConfig(shouldShow: true)
        remote.triggerToPaywalls["remote_alias"] = remote.triggerToPaywalls["checkout"]
        var bundled = remote
        bundled.triggerToPaywalls["bundle_only"] = remote.triggerToPaywalls["checkout"]
        HeliumFallbackViewManager.shared.injectFallbackConfigForTesting(bundled)
        injectConfig(remote)
        HeliumPaywallPresenter.shared.presentUpsellWithLoadingBudget(trigger: "checkout", presentationContext: .empty)
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent } }
        let event = try XCTUnwrap(mockDelegate.receivedEvents.compactMap { $0 as? UserAllocatedEvent }.first)
        XCTAssertEqual(Set(event.experimentInfo.allTriggers ?? []), Set(["checkout", "remote_alias"]))
    }

    func testOpeningWithoutDecisionDoesNotAllocate() throws {
        let config = try experimentConfig(shouldShow: true)
        injectConfig(config)
        let info = try XCTUnwrap(config.triggerToPaywalls["checkout"])
        let session = makeTestSession(trigger: "checkout", paywallInfo: info)
        HeliumActionsDelegate(paywallInfo: info, paywallSession: session, trigger: "checkout")
            .logImpression(viewType: .embedded, fallbackReason: nil)
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is PaywallOpenEvent } }
        XCTAssertTrue(mockDelegate.receivedEvents.contains { $0 is PaywallOpenEvent })
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent })
    }

    func testInspectionDoesNotAllocate() throws {
        let config = try experimentConfig(shouldShow: true)
        injectConfig(config)
        _ = Helium.shared.getPaywallInfo(trigger: "checkout")
        _ = Helium.shared.canShowPaywallFor(trigger: "checkout")
        XCTAssertEqual(config.extractExperimentInfo(trigger: "checkout")?.experimentId, "exp-flow")
        drainMainActor()
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent })
    }

    func testSkipPaywallFiresSkippedEvent() {
        let paywallInfo = makeTestPaywallInfo(trigger: "skip_trigger", shouldShow: false)
        let config = makeTestConfig(triggers: ["skip_trigger": paywallInfo])
        injectConfig(config)

        let context = PaywallPresentationContext.empty
        let skipped = HeliumPaywallPresenter.shared.skipPaywallIfNeeded(trigger: "skip_trigger", presentationContext: context)
        XCTAssertTrue(skipped)

        waitForEventDispatch {
            self.mockDelegate.receivedEvents.contains { $0 is PaywallSkippedEvent }
        }

        // Check delegate received the event
        let skippedEvents = mockDelegate.receivedEvents.compactMap { $0 as? PaywallSkippedEvent }
        XCTAssertEqual(skippedEvents.count, 1)
        XCTAssertEqual(skippedEvents.first?.triggerName, "skip_trigger")
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent })
    }

    func testSkipPaywallCallsOnPaywallNotShown() {
        let paywallInfo = makeTestPaywallInfo(trigger: "skip_trigger", shouldShow: false)
        let config = makeTestConfig(triggers: ["skip_trigger": paywallInfo])
        injectConfig(config)

        var notShownReason: PaywallNotShownReason?
        let context = PaywallPresentationContext(
            config: PaywallPresentationConfig(),
            eventHandlers: nil,
            onEntitled: nil,
            onPaywallNotShown: { reason in notShownReason = reason }
        )

        let skipped = HeliumPaywallPresenter.shared.skipPaywallIfNeeded(trigger: "skip_trigger", presentationContext: context)
        XCTAssertTrue(skipped)
        XCTAssertEqual(notShownReason, .targetingHoldout)
    }

    func testNoSkipWhenShouldShowIsTrue() {
        let paywallInfo = makeTestPaywallInfo(trigger: "show_trigger", shouldShow: true)
        let config = makeTestConfig(triggers: ["show_trigger": paywallInfo])
        injectConfig(config)

        let skipped = HeliumPaywallPresenter.shared.skipPaywallIfNeeded(trigger: "show_trigger", presentationContext: .empty)
        XCTAssertFalse(skipped)
    }

    func testNoSkipWhenShouldShowIsNil() {
        let paywallInfo = makeTestPaywallInfo(trigger: "nil_trigger", shouldShow: nil)
        let config = makeTestConfig(triggers: ["nil_trigger": paywallInfo])
        injectConfig(config)

        let skipped = HeliumPaywallPresenter.shared.skipPaywallIfNeeded(trigger: "nil_trigger", presentationContext: .empty)
        XCTAssertFalse(skipped)
    }
}
