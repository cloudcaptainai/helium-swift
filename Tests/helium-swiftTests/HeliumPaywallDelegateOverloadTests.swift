import XCTest
@testable import Helium

/// Implements only `makePurchase(productId:)`; the promo overload must resolve to
/// the protocol's default implementation.
private final class SingleArgPurchaseDelegate: HeliumPaywallDelegate {
    var receivedProductIds: [String] = []

    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        receivedProductIds.append(productId)
        return .purchased
    }
}

private final class PromoRecordingDelegate: HeliumPaywallDelegate {
    var received: [(productId: String, promoOfferId: String)] = []
    var supportsPromotionalOffers: Bool { true }

    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        .failed(NSError(domain: "unexpected", code: 0))
    }

    func makePurchase(productId: String, promoOfferId: String) async -> HeliumPaywallTransactionStatus {
        received.append((productId, promoOfferId))
        return .purchased
    }
}

final class HeliumPaywallDelegateOverloadTests: HeliumTestCase {

    func testDefaultOverloadForwardsBareId() async {
        let delegate = SingleArgPurchaseDelegate()
        let status = await delegate.makePurchase(productId: "test_yearly", promoOfferId: "OFFER50")
        XCTAssertEqual(delegate.receivedProductIds, ["test_yearly"])
        guard case .purchased = status else {
            return XCTFail("expected purchased")
        }
    }

    func testOverridingDelegateReceivesBothArguments() async {
        let delegate = PromoRecordingDelegate()
        _ = await delegate.makePurchase(productId: "test_yearly", promoOfferId: "OFFER50")
        XCTAssertEqual(delegate.received.count, 1)
        XCTAssertEqual(delegate.received[0].productId, "test_yearly")
        XCTAssertEqual(delegate.received[0].promoOfferId, "OFFER50")
    }

    func testSupportsPromotionalOffersDefaultsToFalse() {
        XCTAssertFalse(SingleArgPurchaseDelegate().supportsPromotionalOffers)
        XCTAssertTrue(PromoRecordingDelegate().supportsPromotionalOffers)
    }
}
