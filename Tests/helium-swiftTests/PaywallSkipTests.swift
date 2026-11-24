import XCTest
import SwiftUI
import UIKit
@testable import Helium

private actor SuspendedPaywallEntitlementsSource: ThirdPartyEntitlementsSource {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Set<String>, Never>?
    private var released = false

    init(started: XCTestExpectation) {
        self.started = started
    }

    func purchasedHeliumProductIds() async -> Set<String> {
        if released { return [] }
        return await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume(returning: [])
        continuation = nil
    }

    func hasAnyActiveSubscription() async -> Bool { false }
    func activeSubscriptions() async -> Set<String> { [] }
    nonisolated func invalidateCache() {}
}

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

    private func configureFallbackView() throws {
        Helium.shared.markInitializedForTesting()
        var info = makeTestPaywallInfo(paywallName: "default_fallback_paywall", products: ["fallback.product"])
        info.resolvedConfig = AnyCodable([
            "baseStack": ["componentProps": ["bundleURL": "https://cdn.example.com/bundles/bundle_skip_test.html"]]
        ] as [String: Any])
        let config = makeTestConfig(
            triggers: [HeliumFallbackViewManager.defaultFallbackTrigger: info],
            bundles: ["skip_test": "<html>fallback</html>"]
        )
        HeliumFallbackViewManager.shared.injectFallbackConfigForTesting(config, json: try JSON(data: JSONEncoder().encode(config)))
        XCTAssertNotNil(HeliumPaywallPresenter.shared.upsellViewResultFor(trigger: "unassigned", presentationContext: .empty).viewAndSession)
    }

    func testDeprecatedViewSkipsInsteadOfReturningConfiguredFallback() throws {
        try configureFallbackView()
        injectConfig(try experimentConfig())

        XCTAssertNil(Helium.shared.upsellViewForTrigger(trigger: "checkout"))
        XCTAssertNil(HeliumPaywallPresenter.shared.upsellViewResultFor(trigger: "checkout", presentationContext: .empty).viewAndSession)
        drainMainActor()

        let events = mockDelegate.receivedEvents
        XCTAssertEqual(events.filter { $0 is UserAllocatedEvent }.count, 1)
        XCTAssertEqual(events.filter { $0 is PaywallSkippedEvent }.count, 1)
        XCTAssertFalse(events.contains { $0 is PaywallOpenEvent || $0 is PaywallOpenFailedEvent || $0 is PaywallCloseEvent })
        XCTAssertFalse(Helium.shared.hidePaywall())
    }

    func testHoldoutInspectionPreservesContentAvailabilityWithoutAllocation() throws {
        try configureFallbackView()
        injectConfig(try experimentConfig())

        let result = Helium.shared.canShowPaywallFor(trigger: "checkout")
        XCTAssertTrue(result.canShow)
        XCTAssertEqual(result.isFallback, true)
        XCTAssertEqual(result.paywallUnavailableReason, .noProductsIOS)
        drainMainActor()
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent || $0 is PaywallSkippedEvent })
        XCTAssertFalse(Helium.shared.hidePaywall())
    }

    func testAllocationSerializationKeepsDecisionSnapshotAfterRefreshOrRemoval() throws {
        var configA = try experimentConfig(shouldShow: true)
        var infoA = try XCTUnwrap(configA.triggerToPaywalls["checkout"])
        infoA.paywallID = 101
        infoA.paywallUUID = "decision-paywall-A"
        configA.triggerToPaywalls["checkout"] = infoA
        injectConfig(configA)
        ExperimentAllocationTracker.shared.recordDecision(trigger: "checkout", paywallInfo: infoA)
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent } }
        let allocation = try XCTUnwrap(mockDelegate.receivedEvents.compactMap { $0 as? UserAllocatedEvent }.first)

        var infoB = infoA
        infoB.paywallID = 202
        infoB.paywallUUID = "refreshed-paywall-B"
        infoB.experimentID = "refreshed-experiment"
        var experimentB = try XCTUnwrap(infoB.experimentInfo)
        experimentB["experimentId"] = JSON("refreshed-experiment")
        experimentB["chosenVariantDetails"]["allocationId"] = JSON("refreshed-arm-B")
        infoB.experimentInfo = experimentB

        for config in [makeTestConfig(triggers: ["checkout": infoB]), makeTestConfig(triggers: [:])] {
            injectConfig(config)
            let payload = testAnalyticsDictionary(HeliumAnalyticsManager.shared.buildLoggedEvent(for: allocation, paywallSession: nil))
            XCTAssertEqual(payload["fetchedConfigId"] as? String, configA.fetchedConfigID.uuidString)
            XCTAssertEqual(payload["experimentID"] as? String, "exp-flow")
            XCTAssertEqual(payload["paywallID"] as? Int, 101)
            XCTAssertEqual(payload["paywallUUID"] as? String, "decision-paywall-A")
            let experiment = try XCTUnwrap(payload["experimentInfo"] as? [String: Any])
            XCTAssertEqual(experiment["experimentId"] as? String, "exp-flow")
            let variant = try XCTUnwrap(experiment["chosenVariantDetails"] as? [String: Any])
            XCTAssertEqual(variant["allocationId"] as? String, "synthetic-arm")
            XCTAssertEqual(experiment["isEnrolled"] as? Bool, true)
            let context = try XCTUnwrap(payload["contextTraits"] as? [String: Any])
            let application = try XCTUnwrap(context["applicationInfo"] as? [String: Any])
            XCTAssertEqual(application["environment"] as? String, AppReceiptsHelper.shared.getEnvironment())
            XCTAssertNil(payload["heliumPaywallSessionId"])
        }
    }

    @MainActor
    func testEmbeddedEntitlementRefreshDoesNotAllocateTwice() throws {
        Helium.shared.markInitializedForTesting()
        var showConfig = try experimentConfig(shouldShow: true)
        var showInfo = try XCTUnwrap(showConfig.triggerToPaywalls["checkout"])
        var experimentInfo = try XCTUnwrap(showInfo.experimentInfo)
        experimentInfo["chosenVariantDetails"]["allocationId"] = JSON("show-arm")
        showInfo.experimentInfo = experimentInfo
        showConfig.triggerToPaywalls["checkout"] = showInfo
        injectConfig(showConfig)

        let started = expectation(description: "Entitlement check suspended")
        let source = SuspendedPaywallEntitlementsSource(started: started)
        Helium.config.thirdPartyEntitlementsSource = source
        let notShown = expectation(description: "Embedded targeting holdout")
        let view = HeliumPaywall(
            trigger: "checkout", config: PaywallPresentationConfig(dontShowIfAlreadyEntitled: true, loadingBudget: 10)
        ) { reason in
            Color.clear.onAppear {
                XCTAssertEqual(reason, .targetingHoldout)
                notShown.fulfill()
            }
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            Helium.config.thirdPartyEntitlementsSource = nil
            Task { await source.release() }
        }
        window.layoutIfNeeded()
        wait(for: [started], timeout: 3)
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent } }

        injectConfig(try experimentConfig())
        Task { await source.release() }
        wait(for: [notShown], timeout: 3)
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is PaywallSkippedEvent } }
        drainMainActor()

        let allocations = mockDelegate.receivedEvents.compactMap { $0 as? UserAllocatedEvent }
        XCTAssertEqual(allocations.map { $0.experimentInfo.chosenVariantDetails?.allocationId }, ["show-arm"])
        XCTAssertEqual(mockDelegate.receivedEvents.filter { $0 is PaywallSkippedEvent }.count, 1)
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is PaywallOpenEvent || $0 is PaywallOpenFailedEvent })
    }

    @MainActor
    func testEmbeddedLateExperimentAllocatesAfterOrdinaryOrMissingAssignment() throws {
        Helium.shared.markInitializedForTesting()
        for triggers in [["checkout": makeTestPaywallInfo()], [:]] {
            ExperimentAllocationTracker.shared.reset()
            injectConfig(makeTestConfig(triggers: triggers))
            let eventStart = mockDelegate.receivedEvents.count
            let started = expectation(description: "Ordinary entitlement check suspended")
            let source = SuspendedPaywallEntitlementsSource(started: started)
            Helium.config.thirdPartyEntitlementsSource = source
            let notShown = expectation(description: "Late experiment holdout")
            let view = HeliumPaywall(
                trigger: "checkout", config: PaywallPresentationConfig(dontShowIfAlreadyEntitled: true, loadingBudget: 10)
            ) { reason in
                Color.clear.onAppear {
                    XCTAssertEqual(reason, .targetingHoldout)
                    notShown.fulfill()
                }
            }
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
            window.rootViewController = UIHostingController(rootView: view)
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                Helium.config.thirdPartyEntitlementsSource = nil
                Task { await source.release() }
            }
            window.layoutIfNeeded()
            wait(for: [started], timeout: 3)
            drainMainActor()
            XCTAssertFalse(mockDelegate.receivedEvents.dropFirst(eventStart).contains { $0 is UserAllocatedEvent })

            injectConfig(try experimentConfig())
            Task { await source.release() }
            wait(for: [notShown], timeout: 3)
            waitForEventDispatch { self.mockDelegate.receivedEvents.dropFirst(eventStart).contains { $0 is PaywallSkippedEvent } }
            drainMainActor()

            let events = Array(mockDelegate.receivedEvents.dropFirst(eventStart))
            XCTAssertEqual(events.filter { $0 is UserAllocatedEvent }.count, 1)
            XCTAssertEqual(events.filter { $0 is PaywallSkippedEvent }.count, 1)
            XCTAssertFalse(events.contains { $0 is PaywallOpenEvent || $0 is PaywallOpenFailedEvent })
        }
    }

    @MainActor
    func testModalSkipsConfigArrivingBeforePresentationBegins() throws {
        try configureFallbackView()
        XCTAssertNil(HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger("checkout"))
        let dispatched = DispatchSemaphore(value: 0)
        let notShown = expectation(description: "Targeting holdout callback")
        DispatchQueue.global().async {
            Helium.shared.presentPaywall(
                trigger: "checkout", config: PaywallPresentationConfig(loadingBudget: 0),
                onPaywallNotShown: {
                    XCTAssertEqual($0, .targetingHoldout)
                    notShown.fulfill()
                }
            )
            dispatched.signal()
        }
        XCTAssertEqual(dispatched.wait(timeout: .now() + 5), .success)
        injectConfig(try experimentConfig())
        waitForEventDispatch {
            self.mockDelegate.receivedEvents.contains { $0 is PaywallSkippedEvent || $0 is PaywallOpenFailedEvent || $0 is PaywallOpenEvent }
        }
        drainMainActor()
        wait(for: [notShown], timeout: 2)

        let events = mockDelegate.receivedEvents
        XCTAssertEqual(events.filter { $0 is UserAllocatedEvent }.count, 1)
        XCTAssertEqual(events.filter { $0 is PaywallSkippedEvent }.count, 1)
        XCTAssertFalse(events.contains { $0 is PaywallOpenEvent || $0 is PaywallOpenFailedEvent || $0 is PaywallCloseEvent })
        XCTAssertFalse(Helium.shared.hidePaywall())
    }

    @MainActor
    func testModalUsesSkipConfigDownloadedWhileDecisionIsQueued() throws {
        try configureFallbackView()
        XCTAssertNil(HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger("checkout"))
        let notShown = expectation(description: "Queued presentation skips")
        Helium.shared.presentPaywall(
            trigger: "checkout", config: PaywallPresentationConfig(loadingBudget: 0),
            onPaywallNotShown: {
                XCTAssertEqual($0, .targetingHoldout)
                notShown.fulfill()
            }
        )
        injectConfig(try experimentConfig())
        waitForEventDispatch {
            self.mockDelegate.receivedEvents.contains { $0 is PaywallSkippedEvent || $0 is PaywallOpenFailedEvent || $0 is PaywallOpenEvent }
        }
        drainMainActor()
        wait(for: [notShown], timeout: 2)

        let events = mockDelegate.receivedEvents
        XCTAssertEqual(events.filter { $0 is UserAllocatedEvent }.count, 1)
        XCTAssertEqual(events.filter { $0 is PaywallSkippedEvent }.count, 1)
        XCTAssertFalse(events.contains { $0 is PaywallOpenEvent || $0 is PaywallOpenFailedEvent || $0 is PaywallCloseEvent })
        XCTAssertFalse(Helium.shared.hidePaywall())
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

    func testMalformedStoredEntryRecoversEnrollmentFromBackup() throws {
        let config = try experimentConfig()
        injectConfig(config)
        let tracker = ExperimentAllocationTracker.shared
        tracker.recordDecision(trigger: "checkout", paywallInfo: config.triggerToPaywalls["checkout"])
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent } }
        let enrolledAt = try XCTUnwrap(config.extractExperimentInfo(trigger: "checkout")?.enrolledAt)
        let original = try XCTUnwrap(UserDefaults.standard.data(forKey: "heliumExperimentAllocations"))
        let fileURL = try XCTUnwrap(heliumAppSupportDirectory).appendingPathComponent("helium_experiment_allocations.json")
        waitForEventDispatch { (try? Data(contentsOf: fileURL)) == original }
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        let persistentId = HeliumIdentityManager.shared.getHeliumPersistentId()
        let malformed = try JSONSerialization.data(withJSONObject: [
            "\(persistentId)_exp-flow": ["allocationIndex": "invalid"]
        ])
        UserDefaults.standard.set(malformed, forKey: "heliumExperimentAllocations")
        tracker.loadStoredAllocations()
        XCTAssertEqual(config.extractExperimentInfo(trigger: "checkout")?.enrolledAt, enrolledAt)
        tracker.recordDecision(trigger: "checkout", paywallInfo: config.triggerToPaywalls["checkout"])
        drainMainActor()
        XCTAssertEqual(mockDelegate.receivedEvents.filter { $0 is UserAllocatedEvent }.count, 1)
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
