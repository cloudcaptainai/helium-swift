import XCTest
@testable import Helium

/// The entitlement call sites compare StoreKit transaction ids (bare) against
/// `productIdsIncludingWebProductIds`, so iOS composites must arrive bare while
/// Stripe/Paddle keys stay intact.
final class PromoEntitlementProductIdsTests: XCTestCase {

    private let composite = "test_yearly:test_yearly_offer_identifier"
    private let stripeKey = "prod_ABC123:price_XYZ789"

    private func makeInfo(ios: [String], stripe: [String]? = nil) -> HeliumPaywallInfo {
        HeliumPaywallInfo(
            paywallID: 1,
            paywallUUID: UUID().uuidString,
            paywallTemplateName: "test_paywall",
            productsOffered: nil,
            productsOfferedIOS: ios,
            productsOfferedStripe: stripe,
            productsOfferedPaddle: nil,
            webProductsOfferedPaddle: nil,
            webProductsOfferedStripe: nil,
            resolvedConfig: AnyCodable([:] as [String: Any]),
            shouldShow: nil,
            fallbackPaywallName: nil,
            experimentID: nil,
            modelID: nil,
            forceShowFallback: nil,
            secondChance: nil,
            secondChancePaywall: nil,
            resolvedConfigJSON: nil,
            experimentInfo: nil,
            additionalPaywallFields: nil,
            presentationStyle: nil
        )
    }

    func testEntitlementIdsStripPromoSuffix() {
        let info = makeInfo(ios: [composite])
        XCTAssertEqual(info.productIdsIncludingWebProductIds, ["test_yearly"])
    }

    func testStoreKitProductIdsDeduplicatesToBareIds() {
        let info = makeInfo(ios: ["test_weekly", composite])
        XCTAssertEqual(info.storeKitProductIds, ["test_weekly", "test_yearly"])
    }

    func testStripeCompositeKeyIsUnchanged() {
        let info = makeInfo(ios: [composite], stripe: [stripeKey])
        let ids = info.productIdsIncludingWebProductIds
        XCTAssertTrue(ids.contains("test_yearly"))
        XCTAssertTrue(ids.contains(stripeKey))
        XCTAssertFalse(ids.contains(composite))
    }
}
