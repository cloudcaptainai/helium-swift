import XCTest
import SwiftUI
@testable import Helium

final class PreviewEligibilityChecksTests: XCTestCase {

    override func setUp() {
        super.setUp()
        resetStore()
    }

    override func tearDown() {
        resetStore()
        super.tearDown()
    }

    private func resetStore() {
        let store = HeliumPreviewConfigurationStore.shared
        store.forceExternalCheckoutSimulation = true
        store.forcePaddleCaConsentModal = false
        store.previewEligibilityIpCountry = nil
        store.eligibilityStatus = .checking
        store.purchaseMode = .simulated
    }

    // MARK: - Rows

    func testAllUSSignalsPass() {
        let rows = HeliumPreviewEligibilityRow.rows(storeCountry: "US", deviceRegion: "US", ipCountry: "US")

        XCTAssertEqual(rows.map(\.text), [
            "App Store country (US)",
            "iPhone Region (US)",
            "Network location (US)",
        ])
        XCTAssertEqual(rows.map(\.isUS), [true, true, true])
    }

    func testNonUSRegionIsTheOnlyFailingRow() {
        let rows = HeliumPreviewEligibilityRow.rows(storeCountry: "US", deviceRegion: "GB", ipCountry: "US")

        XCTAssertEqual(rows.map(\.isUS), [true, false, true])
        XCTAssertEqual(rows[1].text, "iPhone Region (GB)")
    }

    func testMissingNetworkLocationShowsUnknownAndFails() {
        for missing in [nil, "", "  "] as [String?] {
            let rows = HeliumPreviewEligibilityRow.rows(storeCountry: "US", deviceRegion: "US", ipCountry: missing)

            XCTAssertEqual(rows[2].text, "Network location (unknown)")
            XCTAssertFalse(rows[2].isUS)
        }
    }

    func testCountryCodeMatchIsCaseInsensitive() {
        XCTAssertTrue(HeliumPreviewEligibilityRow(label: "Network location", value: " us ").isUS)
    }

    // MARK: - Response and store

    func testDecodesPreviewEligibilityIpCountry() throws {
        let json = """
        {"productIds": [], "paywalls": [], "forceExternalCheckoutSimulation": true, "previewEligibilityIpCountry": "GB"}
        """
        let response = try JSONDecoder().decode(HeliumControlPanelResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.previewEligibilityIpCountry, "GB")
    }

    func testMissingPreviewEligibilityIpCountryDecodesAsNil() throws {
        let json = """
        {"productIds": [], "paywalls": []}
        """
        let response = try JSONDecoder().decode(HeliumControlPanelResponse.self, from: Data(json.utf8))

        XCTAssertNil(response.previewEligibilityIpCountry)
    }

    func testFailedRecheckBlocksRealPurchaseClearedByAnEarlierCheck() throws {
        let store = HeliumPreviewConfigurationStore.shared
        let cleared = try JSONDecoder().decode(HeliumControlPanelResponse.self, from: Data("""
        {"productIds": [], "paywalls": [], "forceExternalCheckoutSimulation": false, "previewEligibilityIpCountry": "US"}
        """.utf8))
        store.applyEligibility(from: cleared)
        XCTAssertEqual(store.purchaseMode, .real)
        XCTAssertEqual(store.eligibilityStatus, .checked)

        store.markEligibilityCheckFailed()

        XCTAssertEqual(store.purchaseMode, .simulated)
        XCTAssertEqual(store.eligibilityStatus, .failed)
    }

    // MARK: - Real purchase card

    private func realPurchaseCardStrings() -> [String] {
        let view = HeliumPreviewConfigurationView(
            request: HeliumPreviewConfigurationRequest(target: .settings),
            onStart: { _ in },
            onCancel: {}
        )
        return Self.strings(in: view.purchaseOption(.real))
    }

    func testBlockedCardShowsTheChecksInsteadOfTheRegionWarning() {
        let store = HeliumPreviewConfigurationStore.shared
        store.forceExternalCheckoutSimulation = true
        store.previewEligibilityIpCountry = "US"
        store.eligibilityStatus = .checked

        let strings = realPurchaseCardStrings()

        XCTAssertTrue(strings.contains(HeliumPreviewConfigurationView.vpnCaption), "\(strings)")
        XCTAssertTrue(strings.contains("Check again"), "\(strings)")
        XCTAssertFalse(strings.contains { $0.contains("Region outside the US") }, "\(strings)")
    }

    func testFailedCheckShowsRetryInsteadOfTheChecks() {
        HeliumPreviewConfigurationStore.shared.markEligibilityCheckFailed()

        let strings = realPurchaseCardStrings()

        XCTAssertTrue(strings.contains(HeliumPreviewConfigurationView.eligibilityCheckFailedText), "\(strings)")
        XCTAssertTrue(strings.contains("Retry"), "\(strings)")
        XCTAssertFalse(strings.contains(HeliumPreviewConfigurationView.vpnCaption), "\(strings)")
    }

    func testEligibleCardShowsNoChecks() {
        HeliumPreviewConfigurationStore.shared.forceExternalCheckoutSimulation = false

        let strings = realPurchaseCardStrings()

        XCTAssertTrue(strings.contains(HeliumPreviewPurchaseMode.real.title), "\(strings)")
        XCTAssertFalse(strings.contains(HeliumPreviewConfigurationView.vpnCaption), "\(strings)")
    }

    /// Every string literal reachable in a SwiftUI view value, including `Text` storage and
    /// localized keys. Content built inside `ForEach` closures is not reachable.
    private static func strings(in value: Any, depth: Int = 0) -> [String] {
        guard depth < 80 else { return [] }
        if let string = value as? String { return [string] }
        var found: [String] = []
        var mirror: Mirror? = Mirror(reflecting: value)
        while let current = mirror {
            for child in current.children {
                found += strings(in: child.value, depth: depth + 1)
            }
            mirror = current.superclassMirror
        }
        return found
    }
}
