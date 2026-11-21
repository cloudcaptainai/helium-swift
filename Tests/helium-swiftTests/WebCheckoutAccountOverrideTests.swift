import XCTest
@testable import Helium

final class WebCheckoutAccountOverrideTests: XCTestCase {

    private let apiKey = "test_api_key_web_checkout_override"

    override func setUp() {
        super.setUp()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        resetHelium()
        relaunchApp()
    }

    override func tearDown() {
        resetHelium()
        Helium.lastApiKeyUsed = nil
        relaunchApp()
        super.tearDown()
    }

    /// A new app launch starts with no override and nothing locked.
    private func relaunchApp() {
        Helium.testing.usesLiveWebCheckoutAccount = false
        Helium.testing.webCheckoutAccountLocked = false
    }

    private func initialize() {
        Helium.shared.initialize(apiKey: apiKey)
    }

    private func resetHelium() {
        let reset = expectation(description: "resetHelium")
        Helium.resetHelium { reset.fulfill() }
        wait(for: [reset], timeout: 5)
    }

    private func sentOverrides() throws -> [String: String?] {
        let onLaunch = CodableUserContext.create(userTraits: nil).buildRequestPayload()["applicationInfo"] as? [String: Any]
        let previews = HeliumControlPanelService.previewUserContext(locale: [:])["applicationInfo"] as? [String: Any]
        let payments = try HeliumPaymentAPIClient.shared.baseRequestBody(provider: .paddle)["applicationInfo"] as? [String: Any]
        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(createApplicationInfo())
        ) as? [String: Any]
        return [
            "on-launch": onLaunch?["webCheckoutAccountOverride"] as? String,
            "preview-paywalls": previews?["webCheckoutAccountOverride"] as? String,
            "payments": payments?["webCheckoutAccountOverride"] as? String,
            "encoded": encoded?["webCheckoutAccountOverride"] as? String,
        ]
    }

    private func assertSent(_ expected: String?, file: StaticString = #filePath, line: UInt = #line) throws {
        for (surface, value) in try sentOverrides() {
            XCTAssertEqual(value, expected, surface, file: file, line: line)
        }
    }

    // MARK: - Request encoding

    func testWithoutTheCall_overrideIsLeftOutOfEveryRequest() throws {
        initialize()

        try assertSent(nil)
    }

    func testCallBeforeInitialize_sendsLiveOnEveryRequest() throws {
        Helium.testing.useLiveWebCheckoutAccount()
        initialize()

        try assertSent("live")
    }

    // MARK: - Locked for the app launch

    func testCallAfterInitialize_isIgnored() throws {
        initialize()
        Helium.testing.useLiveWebCheckoutAccount()

        try assertSent(nil)
    }

    func testResetAndReinitialize_keepTheLiveAccount() throws {
        Helium.testing.useLiveWebCheckoutAccount()
        initialize()
        resetHelium()
        Helium.testing.reset()
        initialize()

        try assertSent("live")
    }

    func testCallBetweenResetAndReinitialize_isIgnored() throws {
        initialize()
        resetHelium()
        Helium.testing.useLiveWebCheckoutAccount()
        initialize()

        try assertSent(nil)
    }

    // MARK: - Real purchase copy

    func testRealPurchaseDetail_namesTheAccountOfTheCheckoutToken() {
        XCTAssertTrue(HeliumPreviewPurchaseMode.real.detail(paddleClientToken: "test_abc").contains("Paddle sandbox account"))
        XCTAssertTrue(HeliumPreviewPurchaseMode.real.detail(paddleClientToken: "live_abc").contains("live Paddle account"))
        for unknown in [nil, ""] {
            let detail = HeliumPreviewPurchaseMode.real.detail(paddleClientToken: unknown)
            XCTAssertFalse(detail.contains("sandbox"))
            XCTAssertFalse(detail.contains("live"))
        }
    }

    func testRealPurchaseDetail_stripeOnlyPaywallNamesNoPaddleAccount() throws {
        let version = try JSONDecoder().decode(HeliumPaywallPreviewVersion.self, from: Data("""
            {"versionId": "v1", "versionStatus": "published", "webPaywallBundleUrl": "https://example.com/bundle_1.html", "webStripeProductIds": ["price_1"]}
            """.utf8))
        let paywall = try JSONDecoder().decode(HeliumPaywallPreviewEntry.self, from: Data("""
            {"paywallUuid": "p1", "paywallName": "Stripe paywall", "versions": []}
            """.utf8))
        let stripeOnly = HeliumPreviewConfigurationRequest(target: .version(version, paywall: paywall))

        for token in ["test_abc", "live_abc"] {
            XCTAssertEqual(
                stripeOnly.purchaseDetail(.real, checkoutPaddleClientToken: token),
                HeliumPreviewPurchaseMode.real.detail(paddleClientToken: nil)
            )
        }
        XCTAssertTrue(
            HeliumPreviewConfigurationRequest(target: .settings)
                .purchaseDetail(.real, checkoutPaddleClientToken: "test_abc")
                .contains("Paddle sandbox account")
        )
    }
}
