import XCTest
import Compression
@testable import Helium

final class WebCheckoutPreviewConfigTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Helium.lastApiKeyUsed = "test_api_key_preview_config"
        resetStore()
    }

    override func tearDown() {
        Helium.lastApiKeyUsed = nil
        resetStore()
        super.tearDown()
    }

    private func resetStore() {
        let store = HeliumPreviewConfigurationStore.shared
        store.forceExternalCheckoutSimulation = true
        store.forcePaddleCaConsentModal = false
        store.showCaliforniaConsentModal = false
        store.configureBeforeEachPreview = false
        store.purchaseMode = .simulated
    }

    private func buildURL(
        provider: PaymentProviderConfig,
        triggerName: String,
        baseURL: URL = URL(string: "https://bundles-staging.clickthrough.to/o/p/bundle.html")!
    ) throws -> URL {
        let manager = ExternalWebCheckoutManager(
            provider: provider,
            entitlementsSource: HeliumPaymentEntitlementsSource(provider: provider)
        )
        let templateEvent = PurchaseSucceededEvent(
            productId: "", triggerName: triggerName, paywallName: "P",
            storeKitTransactionId: nil, storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.kind
        )
        let analyticsEvent = HeliumAnalyticsManager.shared.buildLoggedEvent(
            for: templateEvent,
            paywallSession: PaywallSession(trigger: triggerName, paywallInfo: nil, fallbackType: .notFallback, presentationContext: .empty)
        )
        return try manager.buildEnrichedCheckoutURL(
            baseURL: baseURL, analyticsEvent: analyticsEvent,
            productKey: "pro_x:pri_y", triggerName: triggerName,
            successURL: "myapp://ok", cancelURL: "myapp://cancel",
            introOfferEligible: true, paddleBootstraps: nil
        )
    }

    private func decodedCtx(from url: URL) throws -> [String: Any] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let fragment = try XCTUnwrap(components.fragment)
        XCTAssertTrue(fragment.hasPrefix("ctx="))
        let compressed = try XCTUnwrap(base64URLDecode(String(fragment.dropFirst("ctx=".count))))
        let decompressed = try decompressWithAppleZlib(compressed, originalSize: 16384)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: decompressed) as? [String: Any])
    }

    private func queryNames(of url: URL) throws -> [String] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return (components.queryItems ?? []).map { $0.name }
    }

    // MARK: - Environment and trigger

    func testProductionTrigger_setsEnvironmentAndTriggerAndNoPreviewFields() throws {
        let url = try buildURL(provider: .paddle, triggerName: "onboarding")
        let ctx = try decodedCtx(from: url)

        XCTAssertEqual(
            ctx["environment"] as? String,
            AppReceiptsHelper.shared.environment.rawValue.uppercased()
        )
        XCTAssertEqual(ctx["trigger"] as? String, "onboarding")
        XCTAssertNil(ctx["forceSimulatedFlow"])
        XCTAssertFalse(try queryNames(of: url).contains("helium_force_california"))
    }

    func testPreviewTrigger_setsTriggerInCtx() throws {
        let url = try buildURL(provider: .paddle, triggerName: HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER)
        let ctx = try decodedCtx(from: url)

        XCTAssertEqual(ctx["trigger"] as? String, HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER)
    }

    // MARK: - Purchase simulation

    func testPreviewTrigger_simulatedModeSetsForceSimulatedFlowTrue() throws {
        let url = try buildURL(provider: .paddle, triggerName: HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER)
        let ctx = try decodedCtx(from: url)

        XCTAssertEqual(ctx["forceSimulatedFlow"] as? Bool, true)
    }

    func testPreviewTrigger_realModeSetsForceSimulatedFlowFalse() throws {
        let store = HeliumPreviewConfigurationStore.shared
        store.forceExternalCheckoutSimulation = false
        store.purchaseMode = .real

        let url = try buildURL(provider: .paddle, triggerName: HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER)
        let ctx = try decodedCtx(from: url)

        XCTAssertEqual(ctx["forceSimulatedFlow"] as? Bool, false)
    }

    func testForceExternalCheckoutSimulation_overridesRealSelection() throws {
        let store = HeliumPreviewConfigurationStore.shared
        store.purchaseMode = .real
        store.forceExternalCheckoutSimulation = true

        let url = try buildURL(provider: .paddle, triggerName: HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER)
        let ctx = try decodedCtx(from: url)

        XCTAssertEqual(ctx["forceSimulatedFlow"] as? Bool, true)
    }

    // MARK: - California force flag

    func testPreviewTrigger_paddleWithCaToggleAppendsForceCaliforniaParam() throws {
        HeliumPreviewConfigurationStore.shared.showCaliforniaConsentModal = true

        let url = try buildURL(provider: .paddle, triggerName: HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let item = try XCTUnwrap((components.queryItems ?? []).first { $0.name == "helium_force_california" })

        XCTAssertEqual(item.value, "true")
    }

    func testPreviewTrigger_stripeWithCaToggleDoesNotAppendParam() throws {
        HeliumPreviewConfigurationStore.shared.showCaliforniaConsentModal = true

        let url = try buildURL(provider: .stripe, triggerName: HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER)

        XCTAssertFalse(try queryNames(of: url).contains("helium_force_california"))
    }

    func testPreviewTrigger_caToggleOffLeavesQueryUnchanged() throws {
        let url = try buildURL(provider: .paddle, triggerName: HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER)

        XCTAssertFalse(try queryNames(of: url).contains("helium_force_california"))
    }

    func testForcedCaConsentModal_appendsParamEvenWithToggleOff() throws {
        let store = HeliumPreviewConfigurationStore.shared
        store.showCaliforniaConsentModal = false
        store.forcePaddleCaConsentModal = true

        let url = try buildURL(provider: .paddle, triggerName: HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER)

        XCTAssertTrue(try queryNames(of: url).contains("helium_force_california"))
    }

    // MARK: - Response decoding

    func testDecodesForceExternalCheckoutSimulation() throws {
        let json = """
        {"productIds": [], "paywalls": [], "forceExternalCheckoutSimulation": false}
        """
        let response = try JSONDecoder().decode(HeliumControlPanelResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.forceExternalCheckoutSimulation, false)
    }

    func testMissingForceExternalCheckoutSimulationDecodesAsNil() throws {
        let json = """
        {"productIds": [], "paywalls": []}
        """
        let response = try JSONDecoder().decode(HeliumControlPanelResponse.self, from: Data(json.utf8))

        XCTAssertNil(response.forceExternalCheckoutSimulation)
        XCTAssertNil(response.forcePaddleCaConsentModal)
    }

    func testDecodesForcePaddleCaConsentModal() throws {
        let json = """
        {"productIds": [], "paywalls": [], "forcePaddleCaConsentModal": true}
        """
        let response = try JSONDecoder().decode(HeliumControlPanelResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.forcePaddleCaConsentModal, true)
    }

    // MARK: - Helpers

    private func base64URLDecode(_ encoded: String) -> Data? {
        var s = encoded.replacingOccurrences(of: "-", with: "+")
                       .replacingOccurrences(of: "_", with: "/")
        let padNeeded = (4 - (s.count % 4)) % 4
        s += String(repeating: "=", count: padNeeded)
        return Data(base64Encoded: s)
    }

    private func decompressWithAppleZlib(_ data: Data, originalSize: Int) throws -> Data {
        let capacity = max(originalSize, 64) * 2 + 64
        var dst = [UInt8](repeating: 0, count: capacity)
        let decoded = data.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Int in
            guard let baseAddr = srcPtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                &dst, capacity,
                baseAddr.assumingMemoryBound(to: UInt8.self), data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard decoded > 0 || originalSize == 0 else {
            throw NSError(domain: "WebCheckoutPreviewConfigTests", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Apple's compression_decode_buffer failed to decode (returned \(decoded))"])
        }
        return Data(dst.prefix(decoded))
    }
}
