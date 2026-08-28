import XCTest
@testable import Helium

final class PreviewBundleFreshnessTests: XCTestCase {

    private let cutoff = HeliumPreviewBundleFreshness.app2webCutoffMs

    private func makeVersion(webPaywallBundleUrl: String?) throws -> HeliumPaywallPreviewVersion {
        var object: [String: Any] = ["versionId": "v1", "versionStatus": "draft"]
        if let webPaywallBundleUrl { object["webPaywallBundleUrl"] = webPaywallBundleUrl }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(HeliumPaywallPreviewVersion.self, from: data)
    }

    private func bundleURL(builtAtMs: Int64) -> String {
        "https://bundles.t3.storage.dev/org/paywall/bundle_\(builtAtMs).html"
    }

    func testFreshWhenBuiltAfterCutoff() throws {
        let version = try makeVersion(webPaywallBundleUrl: bundleURL(builtAtMs: cutoff + 60_000))
        XCTAssertTrue(version.isApp2webBundleFresh)
    }

    func testStaleWhenBuiltBeforeCutoff() throws {
        let version = try makeVersion(webPaywallBundleUrl: bundleURL(builtAtMs: cutoff - 60_000))
        XCTAssertFalse(version.isApp2webBundleFresh)
    }

    // Cutoff is inclusive: a bundle stamped exactly at it is fresh.
    func testFreshAtExactCutoff() throws {
        let version = try makeVersion(webPaywallBundleUrl: bundleURL(builtAtMs: cutoff))
        XCTAssertTrue(version.isApp2webBundleFresh)
    }

    func testStaleWhenBundleUrlMissing() throws {
        let version = try makeVersion(webPaywallBundleUrl: nil)
        XCTAssertFalse(version.isApp2webBundleFresh)
    }

    func testStaleWhenTimestampUnparseable() throws {
        let version = try makeVersion(
            webPaywallBundleUrl: "https://bundles.t3.storage.dev/org/paywall/bundle_draft.html"
        )
        XCTAssertFalse(version.isApp2webBundleFresh)
    }
}
