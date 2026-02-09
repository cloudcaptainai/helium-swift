import XCTest
@testable import Helium

// MARK: - MockHeliumPaywallDelegate

class MockHeliumPaywallDelegate: HeliumPaywallDelegate {
    var purchaseResult: HeliumPaywallTransactionStatus = .purchased
    var restoreResult: Bool = false

    var makePurchaseCalls: [String] = []
    var restorePurchasesCalled: Int = 0
    var receivedEvents: [HeliumEvent] = []

    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        makePurchaseCalls.append(productId)
        return purchaseResult
    }

    func restorePurchases() async -> Bool {
        restorePurchasesCalled += 1
        return restoreResult
    }

    func onPaywallEvent(_ event: HeliumEvent) {
        receivedEvents.append(event)
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
        Helium.resetHelium()
        mockDelegate = MockHeliumPaywallDelegate()
        Helium.config.purchaseDelegate = mockDelegate
        listener = CapturingEventListener()
        Helium.shared.addHeliumEventListener(listener)
        // Give the async queue time to register the listener
        waitForListenerRegistration()
    }

    override func tearDown() {
        // Flush any pending async events so they don't leak into the next test
        waitForEventDispatch()
        Helium.resetHelium()
        super.tearDown()
    }

    /// Wait for the listener dispatch queue to process pending add/remove operations
    func waitForListenerRegistration() {
        let exp = XCTestExpectation(description: "Listener queue flush")
        // HeliumEventListeners uses a serial queue for add/remove.
        // dispatchEvent does a queue.sync read, so doing a dispatch+MainActor round-trip
        // ensures the add has completed.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    /// Wait for async event dispatch to complete.
    /// fireEvent uses Task { @MainActor } and listeners dispatch via Task { @MainActor }.
    /// We need to wait for: 1) the dispatch queue sync, 2) MainActor task completion.
    func waitForEventDispatch(timeout: TimeInterval = 1.0) {
        // Two round-trips through MainActor to ensure all dispatched tasks complete
        let exp = XCTestExpectation(description: "Event dispatch")
        Task { @MainActor in
            // First MainActor hop (fireEvent's Task { @MainActor })
            Task { @MainActor in
                // Second MainActor hop (listener dispatch's Task { @MainActor })
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: timeout)
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
