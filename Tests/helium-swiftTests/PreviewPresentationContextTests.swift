import XCTest
@testable import Helium

final class PreviewPresentationContextTests: XCTestCase {
    private let previewTrigger = HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER
    private let secondTryPreviewTrigger = HeliumFetchedConfigManager.HELIUM_PREVIEW_SECOND_TRY_TRIGGER

    private func makeHost(
        onAnyEvent: @escaping (PaywallContextEvent) -> Void = { _ in },
        onClose: @escaping (PaywallCloseEvent) -> Void = { _ in },
        onEntitled: ((PaywallEntitledEvent) -> Void)? = nil,
        customPaywallTraits: HeliumUserTraits? = nil
    ) -> PaywallPresentationContext {
        PaywallPresentationContext(
            config: PaywallPresentationConfig(customPaywallTraits: customPaywallTraits, dontShowIfAlreadyEntitled: true),
            eventHandlers: PaywallEventHandlers().onAnyEvent(onAnyEvent).onClose(onClose),
            onEntitled: onEntitled,
            onPaywallNotShown: { _ in XCTFail("host onPaywallNotShown must not be forwarded to the preview") }
        )
    }

    func testForwardsPreviewEventsToHostHandlers() {
        var received: [String] = []
        let host = makeHost(onAnyEvent: { received.append($0.eventName) })
        let preview = PaywallPresentationContext.preview(inheriting: host, onPreviewClosed: {}, onPreviewNotShown: {})

        preview.eventHandlers?.handleEvent(PurchasePressedEvent(productId: "annual", triggerName: previewTrigger, paywallName: "preview", paymentProcessor: .appStore))
        preview.eventHandlers?.handleEvent(PurchaseCancelledEvent(productId: "annual", triggerName: previewTrigger, paywallName: "preview", paymentProcessor: .appStore))
        preview.eventHandlers?.handleEvent(PurchaseRestoreFailedEvent(triggerName: previewTrigger, paywallName: "preview"))

        XCTAssertEqual(received, ["purchasePressed", "purchaseCancelled", "purchaseRestoreFailed"])
    }

    func testMainPreviewCloseReleasesPanelAndReachesHost() {
        var hostCloses = 0
        var released = 0
        let host = makeHost(onClose: { _ in hostCloses += 1 })
        let preview = PaywallPresentationContext.preview(inheriting: host, onPreviewClosed: { released += 1 }, onPreviewNotShown: {})

        preview.eventHandlers?.handleEvent(PaywallCloseEvent(triggerName: previewTrigger, paywallName: "preview"))

        XCTAssertEqual(hostCloses, 1)
        XCTAssertEqual(released, 1)
    }

    func testSecondTryPreviewCloseReachesHostWithoutReleasingPanel() {
        var hostCloses = 0
        var released = 0
        let host = makeHost(onClose: { _ in hostCloses += 1 })
        let preview = PaywallPresentationContext.preview(inheriting: host, onPreviewClosed: { released += 1 }, onPreviewNotShown: {})

        preview.eventHandlers?.handleEvent(PaywallCloseEvent(triggerName: secondTryPreviewTrigger, paywallName: "preview", secondTry: true))

        XCTAssertEqual(hostCloses, 1)
        XCTAssertEqual(released, 0)
    }

    func testForwardsHostOnEntitled() {
        var entitled = 0
        let host = makeHost(onEntitled: { _ in entitled += 1 })
        let preview = PaywallPresentationContext.preview(inheriting: host, onPreviewClosed: {}, onPreviewNotShown: {})
        let event = PurchaseSucceededEvent(productId: "annual", triggerName: previewTrigger, paywallName: "preview", storeKitTransactionId: nil, storeKitOriginalTransactionId: nil, paymentProcessor: .appStore)

        preview.onEntitled?(PaywallEntitledEvent(entitlingEvent: event)!)

        XCTAssertEqual(entitled, 1)
    }

    func testNotShownReleasesPanelOnly() {
        var notShown = 0
        let host = makeHost()
        let preview = PaywallPresentationContext.preview(inheriting: host, onPreviewClosed: {}, onPreviewNotShown: { notShown += 1 })

        preview.onPaywallNotShown?(.error(unavailableReason: .paywallsNotDownloaded))

        XCTAssertEqual(notShown, 1)
    }

    func testPreviewNeverSkipsForEntitlement() {
        let host = makeHost()
        let preview = PaywallPresentationContext.preview(inheriting: host, onPreviewClosed: {}, onPreviewNotShown: {})

        XCTAssertFalse(preview.config.dontShowIfAlreadyEntitled)
    }

    func testWorksWithoutHost() {
        var released = 0
        let preview = PaywallPresentationContext.preview(inheriting: nil, onPreviewClosed: { released += 1 }, onPreviewNotShown: {})

        preview.eventHandlers?.handleEvent(PaywallCloseEvent(triggerName: previewTrigger, paywallName: "preview"))

        XCTAssertEqual(released, 1)
        XCTAssertNil(preview.onEntitled)
    }
}
