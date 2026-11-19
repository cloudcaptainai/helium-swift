import XCTest
@testable import Helium

final class WebCheckoutAccountOverrideTests: XCTestCase {

    private let store = HeliumPreviewConfigurationStore.shared

    override func setUp() {
        super.setUp()
        Helium.lastApiKeyUsed = "test_api_key_web_checkout_override"
        resetState()
    }

    override func tearDown() {
        Helium.lastApiKeyUsed = nil
        resetState()
        super.tearDown()
    }

    private func resetState() {
        Helium.testing.webCheckoutAccountOverride = .automatic
        store.nextLaunchWebCheckoutAccount = .automatic
        store.updatePaddleAccount(clientToken: nil)
        Helium.testing.lockWebCheckoutAccountForSession()
    }

    /// Stands in for the next app launch, which fixes the account at `initialize`.
    private func relaunch() {
        Helium.testing.lockWebCheckoutAccountForSession()
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

    func testAutomaticOverride_isLeftOutOfEveryRequest() throws {
        try assertSent(nil)
    }

    func testLiveOverride_isSentOnEveryRequest() throws {
        Helium.testing.webCheckoutAccountOverride = .live
        relaunch()

        try assertSent("live")
    }

    func testReset_clearsTheOverride() throws {
        Helium.testing.webCheckoutAccountOverride = .live
        relaunch()
        Helium.testing.reset()
        relaunch()

        XCTAssertEqual(Helium.testing.webCheckoutAccountOverride, .automatic)
        try assertSent(nil)
    }

    // MARK: - Fixed per session

    func testCodeChangeAfterInitialize_waitsForTheNextLaunch() throws {
        Helium.testing.webCheckoutAccountOverride = .live

        try assertSent(nil)
        relaunch()
        try assertSent("live")
    }

    func testPreviewLiveChoice_waitsForTheNextLaunch() throws {
        store.nextLaunchWebCheckoutAccount = .live

        try assertSent(nil)
        relaunch()
        try assertSent("live")
    }

    func testPreviewSandboxChoice_keepsTheSessionLiveUntilTheNextLaunch() throws {
        store.nextLaunchWebCheckoutAccount = .live
        relaunch()
        store.nextLaunchWebCheckoutAccount = .automatic

        try assertSent("live")
        relaunch()
        try assertSent(nil)
    }

    // MARK: - Preview screen

    func testSandboxToken_offersTheAccountChoice() {
        store.updatePaddleAccount(clientToken: "test_abc")

        XCTAssertTrue(store.showsWebCheckoutAccountChoice)
    }

    func testLiveToken_hidesTheAccountChoice() {
        store.updatePaddleAccount(clientToken: "live_abc")

        XCTAssertFalse(store.showsWebCheckoutAccountChoice)
    }

    func testLiveSessionFromThePreviewChoice_keepsOfferingTheWayBack() {
        store.nextLaunchWebCheckoutAccount = .live
        relaunch()
        store.updatePaddleAccount(clientToken: "live_abc")

        XCTAssertTrue(store.showsWebCheckoutAccountChoice)
    }

    func testCodeLiveOverride_hidesTheAccountChoice() {
        Helium.testing.webCheckoutAccountOverride = .live
        relaunch()
        store.updatePaddleAccount(clientToken: "live_abc")

        XCTAssertFalse(store.showsWebCheckoutAccountChoice)
    }

    func testRealPurchaseDetail_namesTheSessionAccount() {
        XCTAssertTrue(HeliumPreviewPurchaseMode.real.detail(onPaddleSandboxAccount: true).contains("sandbox"))
        XCTAssertTrue(HeliumPreviewPurchaseMode.real.detail(onPaddleSandboxAccount: false).contains("live account"))
    }
}
