import XCTest
@testable import Helium

final class HeliumIosProductKeyTests: XCTestCase {

    func testBareProductIdReturnsItself() {
        let parts = HeliumIosProductKey.split("test_yearly")
        XCTAssertEqual(parts.productId, "test_yearly")
        XCTAssertNil(parts.promoOfferId)
    }

    func testCompositeSplitsOnFirstColon() {
        let parts = HeliumIosProductKey.split("test_yearly:test_yearly_offer_identifier")
        XCTAssertEqual(parts.productId, "test_yearly")
        XCTAssertEqual(parts.promoOfferId, "test_yearly_offer_identifier")
    }

    func testAdditionalColonsStayInTheOfferSuffix() {
        let parts = HeliumIosProductKey.split("product:offer:extra")
        XCTAssertEqual(parts.productId, "product")
        XCTAssertEqual(parts.promoOfferId, "offer:extra")
    }

    func testEmptySuffixYieldsNoOffer() {
        let parts = HeliumIosProductKey.split("test_yearly:")
        XCTAssertEqual(parts.productId, "test_yearly")
        XCTAssertNil(parts.promoOfferId)
    }

    func testPaddleCompositeKeyIsUntouched() {
        let key = "pro_01krypc7fqwabtc3hcxsg54qfw:pri_01kxv658enrjcre5b3sr78j72p"
        let parts = HeliumIosProductKey.split(key)
        XCTAssertEqual(parts.productId, key)
        XCTAssertNil(parts.promoOfferId)
    }

    func testStripeCompositeKeyIsUntouched() {
        let key = "prod_ABC123:price_XYZ789"
        let parts = HeliumIosProductKey.split(key)
        XCTAssertEqual(parts.productId, key)
        XCTAssertNil(parts.promoOfferId)
    }

    func testProductIdAccessor() {
        XCTAssertEqual(HeliumIosProductKey.productId("test_yearly:OFFER50"), "test_yearly")
        XCTAssertEqual(HeliumIosProductKey.productId("test_yearly"), "test_yearly")
    }
}
