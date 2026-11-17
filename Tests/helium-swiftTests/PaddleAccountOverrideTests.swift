import XCTest
@testable import Helium

final class PaddleAccountOverrideTests: XCTestCase {

    private let store = HeliumPreviewConfigurationStore.shared

    override func setUp() {
        super.setUp()
        Helium.lastApiKeyUsed = "test_api_key_paddle_override"
        resetState()
    }

    override func tearDown() {
        Helium.lastApiKeyUsed = nil
        resetState()
        super.tearDown()
    }

    private func resetState() {
        Helium.testing.paddleAccountOverride = .automatic
        store.forceExternalCheckoutSimulation = false
        store.paddleSandboxAvailable = false
        store.purchaseMode = .simulated
    }

    private func sentOverrides() throws -> [String: String?] {
        let onLaunch = CodableUserContext.create(userTraits: nil).buildRequestPayload()["applicationInfo"] as? [String: Any]
        let previews = HeliumControlPanelService.previewUserContext(locale: [:])["applicationInfo"] as? [String: Any]
        let payments = try HeliumPaymentAPIClient.shared.baseRequestBody(provider: .paddle)["applicationInfo"] as? [String: Any]
        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(createApplicationInfo())
        ) as? [String: Any]
        return [
            "on-launch": onLaunch?["paddleAccountOverride"] as? String,
            "preview-paywalls": previews?["paddleAccountOverride"] as? String,
            "payments": payments?["paddleAccountOverride"] as? String,
            "encoded": encoded?["paddleAccountOverride"] as? String,
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

    func testProductionOverride_isSentOnEveryRequest() throws {
        Helium.testing.paddleAccountOverride = .production

        try assertSent("production")
    }

    func testReset_clearsTheOverride() throws {
        Helium.testing.paddleAccountOverride = .production
        Helium.testing.reset()

        XCTAssertEqual(Helium.testing.paddleAccountOverride, .automatic)
        try assertSent(nil)
    }

    // MARK: - Preview purchase modes

    func testSandboxTokenShowsThreeModes() {
        store.updatePaddleSandboxAvailability(clientToken: "test_abc", requestedProductionAccount: false)

        XCTAssertEqual(store.purchaseModes, [.simulated, .sandbox, .real])
    }

    func testLiveTokenShowsTwoModes() {
        store.updatePaddleSandboxAvailability(clientToken: "live_abc", requestedProductionAccount: false)

        XCTAssertEqual(store.purchaseModes, [.simulated, .real])
    }

    func testMissingTokenShowsTwoModes() {
        store.updatePaddleSandboxAvailability(clientToken: nil, requestedProductionAccount: false)

        XCTAssertEqual(store.purchaseModes, [.simulated, .real])
    }

    func testLiveTokenFetchedForTheProductionAccount_keepsSandboxAvailable() {
        store.updatePaddleSandboxAvailability(clientToken: "test_abc", requestedProductionAccount: false)
        store.updatePaddleSandboxAvailability(clientToken: "live_abc", requestedProductionAccount: true)

        XCTAssertEqual(store.purchaseModes, [.simulated, .sandbox, .real])
    }

    func testRealPurchaseWithSandboxAvailable_sendsProductionOverride() throws {
        store.paddleSandboxAvailable = true
        store.purchaseMode = .real

        XCTAssertEqual(store.purchaseMode, .real)
        try assertSent("production")
    }

    func testSandboxPurchase_clearsTheOverride() throws {
        store.paddleSandboxAvailable = true
        store.purchaseMode = .real
        store.purchaseMode = .sandbox

        try assertSent(nil)
    }

    func testSimulatedPurchase_sendsNoOverride() throws {
        store.paddleSandboxAvailable = true
        store.purchaseMode = .simulated

        try assertSent(nil)
    }

    func testRealPurchaseWithoutSandbox_sendsNoOverride() throws {
        store.purchaseMode = .real

        try assertSent(nil)
    }

    func testRealPurchaseForcedToSimulatedByRegion_keepsTheProductionAccount() throws {
        store.paddleSandboxAvailable = true
        store.purchaseMode = .real
        store.forceExternalCheckoutSimulation = true

        XCTAssertEqual(store.purchaseMode, .simulated)
        try assertSent("production")
    }

    func testRegionCheckDoesNotForceSandboxToSimulated() {
        store.paddleSandboxAvailable = true
        store.purchaseMode = .sandbox
        store.forceExternalCheckoutSimulation = true

        XCTAssertEqual(store.purchaseMode, .sandbox)
    }
}
