import XCTest
@testable import Helium

// MARK: - MockHeliumPaywallDelegate

class MockHeliumPaywallDelegate: HeliumPaywallDelegate {
    private let lock = NSLock()

    var purchaseResult: HeliumPaywallTransactionStatus = .purchased
    var restoreResult: Bool = false

    private var _makePurchaseCalls: [String] = []
    var makePurchaseCalls: [String] { lock.withLock { _makePurchaseCalls } }

    private var _restorePurchasesCalled: Int = 0
    var restorePurchasesCalled: Int { lock.withLock { _restorePurchasesCalled } }

    private var _receivedEvents: [HeliumEvent] = []
    var receivedEvents: [HeliumEvent] { lock.withLock { _receivedEvents } }

    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        lock.withLock { _makePurchaseCalls.append(productId) }
        return purchaseResult
    }

    func restorePurchases() async -> Bool {
        lock.withLock { _restorePurchasesCalled += 1 }
        return restoreResult
    }

    func onPaywallEvent(_ event: HeliumEvent) {
        lock.withLock { _receivedEvents.append(event) }
    }
}

// MARK: - CapturingEventListener

class CapturingEventListener: HeliumEventListener {
    var capturedEvents: [HeliumEvent] = []

    func onHeliumEvent(event: HeliumEvent) {
        capturedEvents.append(event)
    }

    func eventsOfType<T: HeliumEvent>(_ type: T.Type) -> [T] {
        capturedEvents.compactMap { $0 as? T }
    }

    func lastEvent<T: HeliumEvent>(ofType type: T.Type) -> T? {
        capturedEvents.compactMap { $0 as? T }.last
    }
}

// MARK: - PaywallEventHandlersCaptor

class PaywallEventHandlersCaptor {
    var openEvents: [PaywallOpenEvent] = []
    var closeEvents: [PaywallCloseEvent] = []
    var dismissedEvents: [PaywallDismissedEvent] = []
    var purchaseSucceededEvents: [PurchaseSucceededEvent] = []
    var customActionEvents: [CustomPaywallActionEvent] = []
    var anyEvents: [PaywallContextEvent] = []

    var handlers: PaywallEventHandlers {
        PaywallEventHandlers.withHandlers(
            onOpen: { [weak self] e in self?.openEvents.append(e) },
            onClose: { [weak self] e in self?.closeEvents.append(e) },
            onDismissed: { [weak self] e in self?.dismissedEvents.append(e) },
            onPurchaseSucceeded: { [weak self] e in self?.purchaseSucceededEvents.append(e) },
            onCustomPaywallAction: { [weak self] e in self?.customActionEvents.append(e) },
            onAnyEvent: { [weak self] e in self?.anyEvents.append(e) }
        )
    }
}

// MARK: - HeliumTestCase

class HeliumTestCase: XCTestCase {
    var mockDelegate: MockHeliumPaywallDelegate!
    var listener: CapturingEventListener!

    override func setUp() {
        super.setUp()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        Helium.resetHelium()
        mockDelegate = MockHeliumPaywallDelegate()
        Helium.config.purchaseDelegate = mockDelegate
        listener = CapturingEventListener()
        Helium.shared.addHeliumEventListener(listener)
        // Give the async queue time to register the listener
        waitForListenerRegistration()
    }

    override func tearDown() {
        // Drain any pending MainActor tasks so async events don't leak into the next test.
        // Uses a trivial always-true condition so the poll returns on first RunLoop tick.
        drainMainActor()
        Helium.resetHelium()
        super.tearDown()
    }

    /// Performs a quick RunLoop drain to flush pending MainActor tasks between tests.
    private func drainMainActor() {
        let exp = XCTestExpectation(description: "MainActor drain")
        Task { @MainActor in
            Task { @MainActor in
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }

    /// Polls `HeliumEventListeners.shared.hasListener(_:)` until the expected
    /// registration state is reached or the timeout expires.
    ///
    /// `hasListener` performs a `queue.sync` read on the SDK's internal serial
    /// queue (`com.helium.eventListeners`), which acts as a barrier: it will
    /// block until any prior `queue.async` add/remove operations have drained.
    func waitForListenerRegistration(
        of target: HeliumEventListener? = nil,
        registered: Bool = true,
        timeout: TimeInterval = 2.0
    ) {
        let checkTarget = target ?? listener
        guard let checkTarget else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if HeliumEventListeners.shared.hasListener(checkTarget) == registered { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out waiting for listener \(registered ? "registration" : "removal")")
    }

    /// Waits for async event dispatch to complete by polling a condition.
    ///
    /// SDK dispatch path that this must wait through:
    ///   1. `HeliumPaywallDelegateWrapper.fireEvent()` enqueues `Task { @MainActor }`
    ///   2. Inside that task: session handlers fire synchronously, then
    ///      `delegate.onPaywallEvent()` fires, then
    ///      `HeliumEventListeners.shared.dispatchEvent()` is called
    ///   3. `dispatchEvent` captures listeners via `queue.sync`, then enqueues
    ///      another `Task { @MainActor }` to call `onHeliumEvent` on each
    ///
    /// This helper polls the given condition (default: `mockDelegate.receivedEvents`
    /// is non-empty) in a tight RunLoop to avoid brittle fixed delays.
    func waitForEventDispatch(
        timeout: TimeInterval = 2.0,
        condition: (() -> Bool)? = nil
    ) {
        let check = condition ?? { [weak self] in
            guard let self else { return true }
            return !self.mockDelegate.receivedEvents.isEmpty
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        // Condition not met — not necessarily a failure (e.g., tearDown flush
        // when no events were fired), so we don't XCTFail here.
    }
}

// MARK: - Factory Helpers

func makeTestPaywallInfo(
    trigger: String = "test_trigger",
    paywallName: String = "test_paywall",
    products: [String] = ["com.test.product"],
    shouldShow: Bool? = nil,
    forceShowFallback: Bool? = nil
) -> HeliumPaywallInfo {
    return HeliumPaywallInfo(
        paywallID: 1,
        paywallUUID: UUID().uuidString,
        paywallTemplateName: paywallName,
        productsOffered: products,
        productsOfferedIOS: products,
        resolvedConfig: AnyCodable([:] as [String: Any]),
        shouldShow: shouldShow,
        fallbackPaywallName: nil,
        experimentID: nil,
        modelID: nil,
        forceShowFallback: forceShowFallback,
        secondChance: nil,
        secondChancePaywall: nil,
        resolvedConfigJSON: nil,
        experimentInfo: nil,
        additionalPaywallFields: nil,
        presentationStyle: nil
    )
}

func makeTestConfig(
    triggers: [String: HeliumPaywallInfo],
    bundles: [String: String]? = ["dummy_bundle": "<html></html>"]
) -> HeliumFetchedConfig {
    return HeliumFetchedConfig(
        triggerToPaywalls: triggers,
        segmentBrowserWriteKey: "test_key",
        segmentAnalyticsEndpoint: "https://test.example.com",
        orgName: "TestOrg",
        organizationID: "org_123",
        fetchedConfigID: UUID(),
        additionalFields: nil,
        bundles: bundles,
        generatedAt: nil
    )
}

func injectConfig(_ config: HeliumFetchedConfig) {
    HeliumFetchedConfigManager.shared.injectConfigForTesting(config)
}

func makeTestSession(
    trigger: String = "test_trigger",
    eventHandlers: PaywallEventHandlers? = nil,
    paywallInfo: HeliumPaywallInfo? = nil
) -> PaywallSession {
    let context = PaywallPresentationContext(
        config: PaywallPresentationConfig(),
        eventHandlers: eventHandlers,
        onEntitled: nil,
        onPaywallNotShown: nil
    )
    let info = paywallInfo ?? makeTestPaywallInfo(trigger: trigger)
    return PaywallSession(
        trigger: trigger,
        paywallInfo: info,
        fallbackType: .notFallback,
        presentationContext: context
    )
}
