import XCTest
@testable import Helium

/// `Helium.config` is shared process-wide state, so every test configures it in full
/// and `tearDown` resets it.
final class WebCheckoutRedirectTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Helium.config.disableExternalWebCheckout()
    }

    override func tearDown() {
        Helium.config.disableExternalWebCheckout()
        super.tearDown()
    }

    private func classify(_ urlString: String) -> HeliumCheckoutRedirectType? {
        WebCheckoutRedirect.classify(URL(string: urlString)!)
    }

    // MARK: - Single redirect URL (standard configuration)

    private func enableSingleURL(_ redirectURL: String = "myapp://checkout/return") {
        Helium.config.enableExternalWebCheckout(redirectURL: redirectURL, paymentProcessors: .all)
    }

    func testSingleURL_noQueryItems_isCancel() {
        enableSingleURL()
        XCTAssertEqual(classify("myapp://checkout/return"), .cancel)
    }

    func testSingleURL_transactionId_isSuccess() {
        enableSingleURL()
        XCTAssertEqual(classify("myapp://checkout/return?transactionId=txn_123"), .success)
    }

    func testSingleURL_emptyTransactionId_isInconclusive() {
        enableSingleURL()
        XCTAssertNil(classify("myapp://checkout/return?transactionId="))
    }

    func testSingleURL_alreadySubscribedTrue_isSuccess() {
        enableSingleURL()
        XCTAssertEqual(classify("myapp://checkout/return?alreadySubscribed=true"), .success)
    }

    func testSingleURL_alreadySubscribedFalse_isInconclusive() {
        enableSingleURL()
        XCTAssertNil(classify("myapp://checkout/return?alreadySubscribed=false"))
    }

    func testSingleURL_error_isPaymentFailure() {
        enableSingleURL()
        XCTAssertEqual(classify("myapp://checkout/return?error=card_declined"), .paymentFailure)
    }

    func testSingleURL_unrelatedQueryParams_isInconclusive() {
        enableSingleURL()
        XCTAssertNil(classify("myapp://checkout/return?utm_source=email"))
    }

    func testSingleURL_transactionIdWinsOverError() {
        enableSingleURL()
        XCTAssertEqual(classify("myapp://checkout/return?transactionId=txn_123&error=oops"), .success)
    }

    func testSingleURL_nonMatchingURLs_returnNil() {
        enableSingleURL()
        XCTAssertNil(classify("otherapp://checkout/return"))
        XCTAssertNil(classify("myapp://other/return"))
        XCTAssertNil(classify("myapp://checkout/other"))
    }

    func testSingleURL_trailingSlashNormalization() {
        enableSingleURL("https://example.com/return/")
        XCTAssertEqual(classify("https://example.com/return"), .cancel)

        Helium.config.disableExternalWebCheckout()
        enableSingleURL("https://example.com/return")
        XCTAssertEqual(classify("https://example.com/return/"), .cancel)
    }

    func testSingleURL_emptyPathNormalization() {
        enableSingleURL("myapp://openapp")
        XCTAssertEqual(classify("myapp://openapp/"), .cancel)
        XCTAssertEqual(classify("myapp://openapp?transactionId=txn_1"), .success)
    }

    func testSingleURL_stripeSessionIdPlaceholder_matchesByPrefix() {
        enableSingleURL("https://example.com/return/{CHECKOUT_SESSION_ID}")
        XCTAssertEqual(classify("https://example.com/return/cs_test_abc?transactionId=txn_1"), .success)
        XCTAssertEqual(classify("https://example.com/return/cs_test_abc"), .cancel)
    }

    func testNotConfigured_returnsNil() {
        XCTAssertNil(classify("myapp://checkout/return"))
    }

    // MARK: - Legacy distinct success/cancel URLs (deprecated configuration)

    private func enableLegacyDistinctURLs() {
        // Deliberately exercises the deprecated overload with distinct URLs.
        Helium.config.enableExternalWebCheckout(
            successURL: "myapp://checkout/success",
            cancelURL: "myapp://checkout/cancel",
            paymentProcessors: .all
        )
    }

    func testLegacyDistinctURLs_baseMatchIsAuthoritative() {
        enableLegacyDistinctURLs()
        XCTAssertEqual(classify("myapp://checkout/success"), .success)
        XCTAssertEqual(classify("myapp://checkout/cancel"), .cancel)
        XCTAssertEqual(classify("myapp://checkout/cancel?transactionId=txn_1"), .cancel)
        XCTAssertNil(classify("myapp://checkout/other"))
    }

    // MARK: - Configuration validation

    func testEnable_schemelessRedirectURL_staysDisabled() {
        Helium.config.enableExternalWebCheckout(redirectURL: "no-scheme", paymentProcessors: .all)
        XCTAssertFalse(Helium.config.webCheckoutEnabled)
        XCTAssertNil(Helium.config.checkoutSuccessURL)
        XCTAssertNil(Helium.config.checkoutCancelURL)
    }

    func testEnable_emptyProcessors_staysDisabled() {
        Helium.config.enableExternalWebCheckout(redirectURL: "myapp://checkout/return", paymentProcessors: [])
        XCTAssertFalse(Helium.config.webCheckoutEnabled)
        XCTAssertNil(Helium.config.checkoutSuccessURL)
        XCTAssertNil(Helium.config.checkoutCancelURL)
    }

    func testEnable_redirectURLWithQuery_isAccepted() {
        Helium.config.enableExternalWebCheckout(redirectURL: "myapp://checkout/return?src=app", paymentProcessors: .all)
        XCTAssertTrue(Helium.config.webCheckoutEnabled)
    }

    func testEnable_singleURL_setsBothInternalURLs() {
        enableSingleURL()
        XCTAssertTrue(Helium.config.webCheckoutEnabled)
        XCTAssertEqual(Helium.config.checkoutSuccessURL, "myapp://checkout/return")
        XCTAssertEqual(Helium.config.checkoutCancelURL, "myapp://checkout/return")
    }

    func testDisable_clearsConfiguration() {
        enableSingleURL()
        Helium.config.disableExternalWebCheckout()
        XCTAssertFalse(Helium.config.webCheckoutEnabled)
        XCTAssertNil(Helium.config.checkoutSuccessURL)
        XCTAssertNil(Helium.config.checkoutCancelURL)
    }
}
