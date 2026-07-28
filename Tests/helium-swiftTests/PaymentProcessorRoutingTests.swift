import XCTest
@testable import Helium

final class PaymentProcessorRoutingTests: XCTestCase {

    // MARK: - Composite keys that must not reach StoreKit

    func testPaddleCompositeKeyIsRecognised() {
        XCTAssertTrue(HeliumPaymentProcessor.isWebProcessorCompositeKey(
            "pro_01krypc7fqwabtc3hcxsg54qfw:pri_01kxv658enrjcre5b3sr78j72p"))
    }

    func testStripeCompositeKeyIsRecognised() {
        XCTAssertTrue(HeliumPaymentProcessor.isWebProcessorCompositeKey(
            "prod_ABC123:price_XYZ789"))
    }

    // MARK: - StoreKit identifiers that must still route to StoreKit

    func testBareStoreKitIdentifierIsNotACompositeKey() {
        XCTAssertFalse(HeliumPaymentProcessor.isWebProcessorCompositeKey("com.example.app.pro_yearly"))
    }

    func testStoreKitIdentifierContainingAColonIsNotACompositeKey() {
        // Both halves have to match a provider's prefix pair, so an identifier
        // that merely contains a colon keeps its StoreKit routing.
        XCTAssertFalse(HeliumPaymentProcessor.isWebProcessorCompositeKey("com.example.app:yearly"))
    }

    func testAndroidStyleBasePlanKeyIsNotACompositeKey() {
        XCTAssertFalse(HeliumPaymentProcessor.isWebProcessorCompositeKey("premium_sub:monthly-base"))
    }

    // MARK: - Half-matches

    func testPaddleProductWithStripePricePrefixIsNotACompositeKey() {
        // Mixing one provider's product prefix with another's price prefix is
        // not a shape either provider emits.
        XCTAssertFalse(HeliumPaymentProcessor.isWebProcessorCompositeKey("pro_abc:price_xyz"))
    }

    func testProductPrefixWithoutPricePrefixIsNotACompositeKey() {
        XCTAssertFalse(HeliumPaymentProcessor.isWebProcessorCompositeKey("pro_abc:something"))
    }

    func testTrailingColonIsNotACompositeKey() {
        XCTAssertFalse(HeliumPaymentProcessor.isWebProcessorCompositeKey("pro_abc:"))
    }

    func testMultipleColonsAreNotACompositeKey() {
        XCTAssertFalse(HeliumPaymentProcessor.isWebProcessorCompositeKey("pro_abc:pri_xyz:extra"))
    }

    func testEmptyKeyIsNotACompositeKey() {
        XCTAssertFalse(HeliumPaymentProcessor.isWebProcessorCompositeKey(""))
    }

    // MARK: - Error surface

    func testUnregisteredWebProductKeyErrorNamesTheProduct() throws {
        let key = "pro_01krypc7fqwabtc3hcxsg54qfw:pri_01kxv658enrjcre5b3sr78j72p"
        let description = try XCTUnwrap(
            HeliumPaymentRoutingError.unregisteredWebProductKey(key).errorDescription)

        XCTAssertTrue(description.contains(key),
                      "the developer needs to know which product failed to route")
        XCTAssertFalse(description.contains("App Store Connect"),
                       "pointing at App Store Connect is the misdiagnosis this error exists to prevent")
    }
}
