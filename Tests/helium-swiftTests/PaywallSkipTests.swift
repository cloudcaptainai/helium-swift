import XCTest
import SwiftUI
import UIKit
@testable import Helium

private actor SuspendedPaywallEntitlementsSource: ThirdPartyEntitlementsSource {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Set<String>, Never>?
    private var released = false
    private let products: Set<String>

    init(started: XCTestExpectation, products: Set<String> = []) {
        self.started = started
        self.products = products
    }

    func purchasedHeliumProductIds() async -> Set<String> {
        if released { return products }
        return await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume(returning: products)
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

    private func experimentConfig(shouldShow: Bool = false, hasNoPaywallArm: Bool? = nil) throws -> HeliumFetchedConfig {
        let fixture = #"""
        {"shouldShow":false,"experimentID":"exp-flow","paywallID":0,"paywallUUID":"synthetic-arm","paywallVersionUUID":"","paywallTemplateName":"Your paywall","productsOffered":[],"productsOfferedIOS":[],"productsOfferedAndroid":[],"productsOfferedStripe":[],"productsOfferedPaddle":[],"webProductsOfferedStripe":[],"webProductsOfferedPaddle":[],"fallbackPaywallName":"","resolvedConfig":{},"additionalPaywallFields":{},"experimentInfo":{"experimentId":"exp-flow","experimentName":"A/A","experimentType":"A/B/n test","experimentMetadata":{},"experimentVersionId":"skip-version","audienceId":"1","audienceData":"{}","chosenVariantDetails":{"allocationId":"synthetic-arm","allocationName":"Your paywall","allocationIndex":0,"allocationMetadata":{"paywall_id":"synthetic-arm","percentage":50,"variant_type":"control","variant_name":"Your paywall","show_paywall":false}},"hashDetails":{"hashedUserId":"u1","hashedUserIdBucket1To100":42,"hashMethod":"HASH_USER_ID"}}}
        """#
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        object["shouldShow"] = shouldShow
        if let hasNoPaywallArm, var experimentInfo = object["experimentInfo"] as? [String: Any] {
            experimentInfo["hasNoPaywallArm"] = hasNoPaywallArm
            object["experimentInfo"] = experimentInfo
        }
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

    func testSkipExperimentFlagSurvivesExperimentInfoRoundTrip() throws {
        for flag in [nil, false, true] as [Bool?] {
            let config = try experimentConfig(shouldShow: true, hasNoPaywallArm: flag)
            let info = try XCTUnwrap(config.extractExperimentInfo(trigger: "checkout"))
            let encoded = try JSONEncoder().encode(info)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["hasNoPaywallArm"] as? Bool, flag)
            let restored = try JSONDecoder().decode(ExperimentInfo.self, from: encoded)
            let restoredObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
            XCTAssertEqual(restoredObject["hasNoPaywallArm"] as? Bool, flag)
        }
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
        var configA = try experimentConfig(shouldShow: true, hasNoPaywallArm: true)
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
    func testEmbeddedDecisionKeepsOriginalShowAssignmentAcrossEntitlementRefresh() throws {
        Helium.shared.markInitializedForTesting()
        var showConfig = try experimentConfig(shouldShow: true, hasNoPaywallArm: true)
        var showInfo = try XCTUnwrap(showConfig.triggerToPaywalls["checkout"])
        var experimentInfo = try XCTUnwrap(showInfo.experimentInfo)
        experimentInfo["chosenVariantDetails"]["allocationId"] = JSON("show-arm")
        showInfo.experimentInfo = experimentInfo
        showConfig.triggerToPaywalls["checkout"] = showInfo
        injectConfig(showConfig)

        let started = expectation(description: "Entitlement check suspended")
        let source = SuspendedPaywallEntitlementsSource(started: started)
        Helium.config.thirdPartyEntitlementsSource = source
        let notShown = expectation(description: "Original show arm content unavailable")
        let view = HeliumPaywall(
            trigger: "checkout", config: PaywallPresentationConfig(dontShowIfAlreadyEntitled: true, loadingBudget: 10)
        ) { reason in
            Color.clear.onAppear {
                XCTAssertEqual(reason, .error(unavailableReason: .noProductsIOS))
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

        var replacement = try experimentConfig()
        replacement.triggerToPaywalls["checkout"]?.experimentID = "experiment-B"
        replacement.triggerToPaywalls["checkout"]?.experimentInfo?["experimentId"] = JSON("experiment-B")
        injectConfig(replacement)
        Task { await source.release() }
        wait(for: [notShown], timeout: 3)
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is PaywallSkippedEvent || $0 is PaywallOpenFailedEvent } }
        drainMainActor()

        let allocations = mockDelegate.receivedEvents.compactMap { $0 as? UserAllocatedEvent }
        XCTAssertEqual(allocations.map { $0.experimentInfo.chosenVariantDetails?.allocationId }, ["show-arm"])
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is PaywallSkippedEvent || $0 is PaywallOpenEvent })
        XCTAssertEqual(mockDelegate.receivedEvents.compactMap { $0 as? PaywallOpenFailedEvent }.map(\.paywallUnavailableReason), [.noProductsIOS])
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
    func testLoadingTimeoutCannotReplaceDownloadDecisionDuringEntitlementCheck() throws {
        try configureFallbackView()
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = root
        window.makeKeyAndVisible()
        let started = expectation(description: "Download decision awaiting entitlement")
        let source = SuspendedPaywallEntitlementsSource(started: started)
        Helium.config.thirdPartyEntitlementsSource = source
        let presenter = HeliumPaywallPresenter.shared
        defer {
            _ = presenter.hideUpsell(animated: false)
            drainMainActor()
            window.isHidden = true
            window.rootViewController = nil
            Helium.config.thirdPartyEntitlementsSource = nil
            Task { await source.release() }
        }

        Helium.shared.presentPaywall(
            trigger: "checkout",
            config: PaywallPresentationConfig(presentFromViewController: root, dontShowIfAlreadyEntitled: true, loadingBudget: 1),
            onPaywallNotShown: { _ in }
        )
        waitForEventDispatch { root.presentedViewController is HeliumViewController }
        let loading = try XCTUnwrap(root.presentedViewController as? HeliumViewController)
        XCTAssertTrue(loading.isLoading)

        injectConfig(try experimentConfig(shouldShow: true, hasNoPaywallArm: true))
        NotificationCenter.default.post(name: NSNotification.Name("HeliumConfigDownloadComplete"), object: nil)
        wait(for: [started], timeout: 3)
        var replacement = try experimentConfig()
        replacement.triggerToPaywalls["checkout"]?.experimentID = "experiment-B"
        replacement.triggerToPaywalls["checkout"]?.experimentInfo?["experimentId"] = JSON("experiment-B")
        injectConfig(replacement)

        let released = expectation(description: "Release after loading timeout")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await source.release()
            released.fulfill()
        }
        wait(for: [released], timeout: 4)
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is PaywallOpenEvent } }
        drainMainActor()

        let allocations = mockDelegate.receivedEvents.compactMap { $0 as? UserAllocatedEvent }
        XCTAssertEqual(allocations.map { $0.experimentInfo.experimentId }, ["exp-flow"])
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is PaywallSkippedEvent || $0 is PaywallOpenFailedEvent })
        XCTAssertFalse(loading.isLoading)
        XCTAssertTrue(root.presentedViewController === loading)
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

    @MainActor
    func testInitialModalAssignmentSurvivesBundleDownloadAndConfigRefresh() async throws {
        try configureFallbackView()
        let previousReadiness = Helium.config.enableWebApplePayReadiness
        Helium.config.enableWebApplePayReadiness = false
        ApplePayHelper.shared.setCanMakePaymentsForTesting(true)
        let configRequested = expectation(description: "Initial config requested")
        let bundleRequested = expectation(description: "Initial bundle download suspended")
        var requestCount = 0
        let server = try StalledConfigServer {
            requestCount += 1
            if requestCount == 1 { configRequested.fulfill() }
            if requestCount == 2 { bundleRequested.fulfill() }
        }
        defer {
            HeliumFetchedConfigManager.reset()
            server.stop()
            Helium.config.enableWebApplePayReadiness = previousReadiness
            ApplePayHelper.shared.setCanMakePaymentsForTesting(nil)
        }
        try await server.start()

        var initial = try experimentConfig(shouldShow: true, hasNoPaywallArm: true)
        initial.bundles = nil
        initial.triggerToPaywalls["checkout"]?.productsOfferedIOS = ["com.test.product"]
        initial.triggerToPaywalls["checkout"]?.resolvedConfig = AnyCodable([
            "baseStack": ["componentProps": ["bundleURL": "http://127.0.0.1:\(server.port)/bundle_\(UUID().uuidString).html"]]
        ] as [String: Any])
        HeliumFetchedConfigManager.shared.fetchConfig(endpoint: "http://127.0.0.1:\(server.port)/config", apiKey: "test_key") { _ in }
        await fulfillment(of: [configRequested], timeout: 10)
        server.respondToAll(with: try JSONEncoder().encode(initial))
        await fulfillment(of: [bundleRequested], timeout: 10)
        XCTAssertEqual(HeliumFetchedConfigManager.shared.downloadStatus, .inProgress)
        XCTAssertEqual(HeliumFetchedConfigManager.shared.downloadStep, .bundles)

        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            _ = HeliumPaywallPresenter.shared.hideUpsell(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        Helium.shared.presentPaywall(
            trigger: "checkout", config: PaywallPresentationConfig(presentFromViewController: root, loadingBudget: 10),
            onPaywallNotShown: { reason in XCTFail("Original show assignment should render: \(reason)") }
        )
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent }
        }, object: nil)], timeout: 3)
        let loading = try XCTUnwrap(root.presentedViewController as? HeliumViewController)
        XCTAssertTrue(loading.isLoading)

        var replacement = try experimentConfig()
        replacement.triggerToPaywalls["checkout"]?.experimentID = "experiment-B"
        replacement.triggerToPaywalls["checkout"]?.experimentInfo?["experimentId"] = JSON("experiment-B")
        injectConfig(replacement)
        NotificationCenter.default.post(name: NSNotification.Name("HeliumConfigDownloadComplete"), object: nil)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.mockDelegate.receivedEvents.contains { $0 is PaywallOpenEvent || $0 is PaywallSkippedEvent }
        }, object: nil)], timeout: 3)

        XCTAssertEqual(mockDelegate.receivedEvents.compactMap { ($0 as? UserAllocatedEvent)?.experimentInfo.experimentId }, ["exp-flow"])
        XCTAssertEqual(mockDelegate.receivedEvents.filter { $0 is PaywallOpenEvent }.count, 1)
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is PaywallSkippedEvent || $0 is PaywallOpenFailedEvent })
        XCTAssertFalse(loading.isLoading)
        XCTAssertTrue(root.presentedViewController === loading)
        _ = HeliumPaywallPresenter.shared.hideUpsell(animated: false)
        await Task.yield()
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
        injectConfig(try experimentConfig(shouldShow: true, hasNoPaywallArm: true))
        HeliumPaywallPresenter.shared.presentUpsellWithLoadingBudget(trigger: "checkout", presentationContext: .empty)
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent } }
        let allocation = try XCTUnwrap(mockDelegate.receivedEvents.compactMap { $0 as? UserAllocatedEvent }.first)
        XCTAssertEqual(allocation.experimentInfo.experimentId, "exp-flow")
        XCTAssertEqual(allocation.experimentInfo.chosenVariantDetails?.allocationId, "synthetic-arm")
    }

    @MainActor
    func testPresentationConflictEnrollsBothArms() throws {
        var config = try experimentConfig(shouldShow: true, hasNoPaywallArm: true)
        var skipInfo = try XCTUnwrap(config.triggerToPaywalls["checkout"])
        skipInfo.shouldShow = false
        skipInfo.experimentID = "exp-skip"
        skipInfo.experimentInfo?["experimentId"] = JSON("exp-skip")
        config.triggerToPaywalls["skip"] = skipInfo
        var regularInfo = try XCTUnwrap(config.triggerToPaywalls["checkout"])
        regularInfo.experimentID = "exp-regular"
        regularInfo.experimentInfo?["experimentId"] = JSON("exp-regular")
        regularInfo.experimentInfo?["hasNoPaywallArm"] = JSON.null
        config.triggerToPaywalls["regular"] = regularInfo
        injectConfig(config)

        Helium.shared.presentPaywall(trigger: "already_presenting", onPaywallNotShown: { _ in })
        Helium.shared.presentPaywall(trigger: "checkout", onPaywallNotShown: { _ in })
        Helium.shared.presentPaywall(trigger: "regular", onPaywallNotShown: { _ in })
        Helium.shared.presentPaywall(trigger: "skip", onPaywallNotShown: { _ in })
        waitForEventDispatch {
            self.mockDelegate.receivedEvents.contains { ($0 as? PaywallOpenFailedEvent)?.paywallUnavailableReason == .alreadyPresented }
                && self.mockDelegate.receivedEvents.contains { $0 is PaywallSkippedEvent }
        }
        let triggers = mockDelegate.receivedEvents.compactMap { ($0 as? UserAllocatedEvent)?.trigger }
        XCTAssertEqual(Set(triggers), Set(["checkout", "skip"]))
        XCTAssertTrue(mockDelegate.receivedEvents.contains {
            guard let failure = $0 as? PaywallOpenFailedEvent else { return false }
            return failure.triggerName == "regular" && failure.paywallUnavailableReason == .alreadyPresented
        })
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
        var remote = try experimentConfig(shouldShow: true, hasNoPaywallArm: true)
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

    func testOpeningSkipExperimentWithoutDecisionDoesNotAllocate() throws {
        let config = try experimentConfig(shouldShow: true, hasNoPaywallArm: true)
        injectConfig(config)
        let info = try XCTUnwrap(config.triggerToPaywalls["checkout"])
        let session = makeTestSession(trigger: "checkout", paywallInfo: info)
        HeliumActionsDelegate(paywallInfo: info, paywallSession: session, trigger: "checkout")
            .logImpression(viewType: .embedded, fallbackReason: nil)
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is PaywallOpenEvent } }
        XCTAssertTrue(mockDelegate.receivedEvents.contains { $0 is PaywallOpenEvent })
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent })
    }

    func testRegularDecisionDoesNotAllocate() throws {
        let config = try experimentConfig(shouldShow: true)
        injectConfig(config)
        XCTAssertTrue(ExperimentAllocationTracker.shared.recordDecision(trigger: "checkout", paywallInfo: config.triggerToPaywalls["checkout"]))
        drainMainActor()
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent })
        XCTAssertEqual(config.extractExperimentInfo(trigger: "checkout")?.isEnrolled, false)
    }

    @MainActor
    func testExperimentTypeControlsEnrollmentWhenAlreadyEntitled() throws {
        Helium.shared.markInitializedForTesting()
        for flag in [nil, false, true] as [Bool?] {
            ExperimentAllocationTracker.shared.reset()
            let eventStart = mockDelegate.receivedEvents.count
            var config = try experimentConfig(shouldShow: true, hasNoPaywallArm: flag)
            config.triggerToPaywalls["checkout"]?.productsOfferedIOS = ["entitled.product"]
            injectConfig(config)
            let started = expectation(description: "Entitlement check started")
            let source = SuspendedPaywallEntitlementsSource(started: started, products: ["entitled.product"])
            Helium.config.thirdPartyEntitlementsSource = source
            defer {
                Helium.config.thirdPartyEntitlementsSource = nil
                Task { await source.release() }
            }
            var reason: PaywallNotShownReason?
            Helium.shared.presentPaywall(
                trigger: "checkout",
                config: PaywallPresentationConfig(dontShowIfAlreadyEntitled: true),
                onPaywallNotShown: { reason = $0 }
            )
            wait(for: [started], timeout: 3)
            drainMainActor()
            XCTAssertEqual(mockDelegate.receivedEvents.dropFirst(eventStart).filter { $0 is UserAllocatedEvent }.count, flag == true ? 1 : 0)
            Task { await source.release() }
            waitForEventDispatch { reason != nil }
            XCTAssertEqual(reason, .alreadyEntitled)
            waitForEventDispatch { self.mockDelegate.receivedEvents.dropFirst(eventStart).contains { $0 is PaywallSkippedEvent } }
            let events = Array(mockDelegate.receivedEvents.dropFirst(eventStart))
            XCTAssertEqual(events.filter { $0 is UserAllocatedEvent }.count, flag == true ? 1 : 0)
            XCTAssertEqual(events.compactMap { ($0 as? PaywallSkippedEvent)?.skipReason }, [.alreadyEntitled])
            XCTAssertFalse(events.contains { $0 is PaywallOpenEvent || $0 is PaywallOpenFailedEvent })
        }
    }

    @MainActor
    func testRegularFallbackOpenDoesNotAllocate() throws {
        try configureFallbackView()
        injectConfig(try experimentConfig(shouldShow: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            _ = HeliumPaywallPresenter.shared.hideUpsell(animated: false)
            drainMainActor()
            window.isHidden = true
            window.rootViewController = nil
        }
        Helium.shared.presentPaywall(
            trigger: "checkout",
            config: PaywallPresentationConfig(presentFromViewController: root),
            onPaywallNotShown: { _ in }
        )
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is PaywallOpenEvent } }
        XCTAssertTrue(try XCTUnwrap(root.presentedViewController as? HeliumViewController).isFallback)
        XCTAssertEqual(mockDelegate.receivedEvents.filter { $0 is PaywallOpenEvent }.count, 1)
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent })
    }

    @MainActor
    func testRegularUnavailableModalDoesNotAllocate() throws {
        Helium.shared.markInitializedForTesting()
        injectConfig(try experimentConfig(shouldShow: true))
        var reason: PaywallNotShownReason?
        Helium.shared.presentPaywall(trigger: "checkout", onPaywallNotShown: { reason = $0 })
        waitForEventDispatch { reason != nil }
        XCTAssertEqual(reason, .error(unavailableReason: .noProductsIOS))
        XCTAssertEqual(mockDelegate.receivedEvents.compactMap { ($0 as? PaywallOpenFailedEvent)?.paywallUnavailableReason }, [.noProductsIOS])
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent || $0 is PaywallOpenEvent })
    }

    @MainActor
    func testRegularModalAllocatesOnlyOnOpen() throws {
        Helium.shared.markInitializedForTesting()
        var config = try experimentConfig(shouldShow: true)
        config.triggerToPaywalls["checkout"]?.productsOfferedIOS = ["renderable.product"]
        config.triggerToPaywalls["checkout"]?.resolvedConfig = AnyCodable([
            "baseStack": ["componentProps": ["bundleURL": "https://cdn.example.com/bundles/bundle_regular_modal.html"]]
        ] as [String: Any])
        injectConfig(config)
        let started = expectation(description: "Regular modal waiting for entitlement")
        let source = SuspendedPaywallEntitlementsSource(started: started)
        Helium.config.thirdPartyEntitlementsSource = source
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            Helium.config.thirdPartyEntitlementsSource = nil
            Task { await source.release() }
            _ = HeliumPaywallPresenter.shared.hideUpsell(animated: false)
            drainMainActor()
            window.isHidden = true
            window.rootViewController = nil
        }
        Helium.shared.presentPaywall(
            trigger: "checkout",
            config: PaywallPresentationConfig(presentFromViewController: root, dontShowIfAlreadyEntitled: true),
            onPaywallNotShown: { _ in }
        )
        wait(for: [started], timeout: 3)
        drainMainActor()
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent || $0 is PaywallOpenEvent })
        Task { await source.release() }
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is PaywallOpenEvent } }
        XCTAssertFalse(try XCTUnwrap(root.presentedViewController as? HeliumViewController).isFallback)
        XCTAssertEqual(mockDelegate.receivedEvents.filter { $0 is PaywallOpenEvent }.count, 1)
        XCTAssertEqual(mockDelegate.receivedEvents.filter { $0 is UserAllocatedEvent }.count, 1)
    }

    func testRegularOpenWithoutFetchedConfigDoesNotAllocate() throws {
        let config = try experimentConfig(shouldShow: true)
        injectConfig(config)
        let info = try XCTUnwrap(config.triggerToPaywalls["checkout"])
        let session = makeTestSession(trigger: "checkout", paywallInfo: info)
        HeliumFetchedConfigManager.reset()
        XCTAssertNil(HeliumFetchedConfigManager.shared.getConfig())
        HeliumActionsDelegate(paywallInfo: info, paywallSession: session, trigger: "checkout")
            .logImpression(viewType: .embedded, fallbackReason: nil)
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is PaywallOpenEvent } }
        XCTAssertEqual(mockDelegate.receivedEvents.filter { $0 is PaywallOpenEvent }.count, 1)
        XCTAssertFalse(mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent })
    }

    func testRegularOpenAllocatesOnceFromOpenedSessionSnapshot() throws {
        let config = try experimentConfig(shouldShow: true)
        injectConfig(config)
        let info = try XCTUnwrap(config.triggerToPaywalls["checkout"])
        let session = makeTestSession(trigger: "checkout", paywallInfo: info)
        var replacement = try experimentConfig(shouldShow: true)
        replacement.triggerToPaywalls["checkout"]?.experimentID = "experiment-B"
        replacement.triggerToPaywalls["checkout"]?.experimentInfo?["experimentId"] = JSON("experiment-B")
        injectConfig(replacement)
        let actions = HeliumActionsDelegate(paywallInfo: info, paywallSession: session, trigger: "checkout")
        actions.logImpression(viewType: .embedded, fallbackReason: nil)
        actions.logImpression(viewType: .embedded, fallbackReason: nil)
        waitForEventDispatch { self.mockDelegate.receivedEvents.filter { $0 is PaywallOpenEvent }.count == 2 }
        let allocations = mockDelegate.receivedEvents.compactMap { $0 as? UserAllocatedEvent }
        XCTAssertEqual(allocations.count, 1)
        let allocation = try XCTUnwrap(allocations.first)
        XCTAssertEqual(allocation.experimentInfo.experimentId, "exp-flow")
        XCTAssertEqual(allocation.decisionConfigId, config.fetchedConfigID)
        XCTAssertEqual(allocation.decisionPaywallInfo?.paywallUUID, info.paywallUUID)
        let logged = HeliumAnalyticsManager.shared.buildLoggedEvent(for: allocation, paywallSession: nil)
        XCTAssertEqual(logged.fetchedConfigId, config.fetchedConfigID)
        XCTAssertEqual(logged.experimentID, "exp-flow")
    }

    func testSkipExperimentShowOpenDoesNotAllocateAgain() throws {
        let config = try experimentConfig(shouldShow: true, hasNoPaywallArm: true)
        injectConfig(config)
        let info = try XCTUnwrap(config.triggerToPaywalls["checkout"])
        ExperimentAllocationTracker.shared.recordDecision(trigger: "checkout", paywallInfo: info)
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is UserAllocatedEvent } }
        let session = makeTestSession(trigger: "checkout", paywallInfo: info)
        HeliumActionsDelegate(paywallInfo: info, paywallSession: session, trigger: "checkout")
            .logImpression(viewType: .triggered, fallbackReason: nil)
        waitForEventDispatch { self.mockDelegate.receivedEvents.contains { $0 is PaywallOpenEvent } }
        XCTAssertEqual(mockDelegate.receivedEvents.filter { $0 is UserAllocatedEvent }.count, 1)
        XCTAssertEqual(mockDelegate.receivedEvents.filter { $0 is PaywallOpenEvent }.count, 1)
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
