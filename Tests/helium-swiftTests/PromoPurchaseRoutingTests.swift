import XCTest
@testable import Helium

/// Records which purchase overload was invoked and with what arguments.
private final class RecordingPurchaseDelegate: HeliumPaywallDelegate {
    enum Call {
        case plain(productId: String)
        case promo(productId: String, promoOfferId: String)
    }

    var calls: [Call] = []

    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        calls.append(.plain(productId: productId))
        return .purchased
    }

    func makePurchase(productId: String, promoOfferId: String) async -> HeliumPaywallTransactionStatus {
        calls.append(.promo(productId: productId, promoOfferId: promoOfferId))
        return .purchased
    }
}

final class PromoPurchaseRoutingTests: HeliumTestCase {

    private var recordingDelegate: RecordingPurchaseDelegate!

    override func setUp() {
        super.setUp()
        recordingDelegate = RecordingPurchaseDelegate()
        Helium.config.purchaseDelegate = recordingDelegate
    }

    private func makeSession() -> PaywallSession {
        makeTestSession(trigger: "test_trigger")
    }

    func testCompositeKeyWithExplicitOfferIdRoutesToPromoOverload() async {
        _ = await HeliumPaywallDelegateWrapper.shared.handlePurchase(
            productKey: "test_yearly:test_yearly_offer_identifier",
            triggerName: "test_trigger",
            paywallTemplateName: "test_paywall",
            paywallSession: makeSession(),
            promoOfferId: "test_yearly_offer_identifier"
        )

        guard case .promo(let productId, let promoOfferId) = recordingDelegate.calls.first else {
            return XCTFail("expected promo purchase call, got \(String(describing: recordingDelegate.calls.first))")
        }
        XCTAssertEqual(productId, "test_yearly")
        XCTAssertEqual(promoOfferId, "test_yearly_offer_identifier")
    }

    func testCompositeKeyWithoutExplicitOfferIdStillRoutesToPromoOverload() async {
        _ = await HeliumPaywallDelegateWrapper.shared.handlePurchase(
            productKey: "test_yearly:test_yearly_offer_identifier",
            triggerName: "test_trigger",
            paywallTemplateName: "test_paywall",
            paywallSession: makeSession()
        )

        guard case .promo(let productId, let promoOfferId) = recordingDelegate.calls.first else {
            return XCTFail("expected promo purchase call, got \(String(describing: recordingDelegate.calls.first))")
        }
        XCTAssertEqual(productId, "test_yearly")
        XCTAssertEqual(promoOfferId, "test_yearly_offer_identifier")
    }

    func testBareKeyRoutesToSingleArgPurchase() async {
        _ = await HeliumPaywallDelegateWrapper.shared.handlePurchase(
            productKey: "test_yearly",
            triggerName: "test_trigger",
            paywallTemplateName: "test_paywall",
            paywallSession: makeSession()
        )

        guard case .plain(let productId) = recordingDelegate.calls.first else {
            return XCTFail("expected plain purchase call, got \(String(describing: recordingDelegate.calls.first))")
        }
        XCTAssertEqual(productId, "test_yearly")
    }

    func testStripeCompositeKeyKeepsWebRouting() async {
        // Stripe/Paddle composites must never reach the StoreKit delegate path.
        _ = await HeliumPaywallDelegateWrapper.shared.handlePurchase(
            productKey: "prod_ABC123:price_XYZ789",
            triggerName: "test_trigger",
            paywallTemplateName: "test_paywall",
            paywallSession: makeSession()
        )
        XCTAssertTrue(recordingDelegate.calls.isEmpty)
    }
}
