import XCTest
import UIKit
@testable import Helium

final class PaywallSafeAreaInsetsTests: XCTestCase {

    private let windowBounds = CGRect(x: 0, y: 0, width: 393, height: 852)
    private let windowInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)

    func testFullScreenViewKeepsWindowInsets() {
        // Paywall web views extend 1pt past each horizontal edge.
        let clipped = PaywallSafeAreaInsets.clipped(
            windowInsets: windowInsets,
            windowBounds: windowBounds,
            viewFrame: CGRect(x: -1, y: 0, width: 395, height: 852)
        )
        XCTAssertEqual(clipped, windowInsets)
    }

    func testViewBelowHeaderDropsTopInset() {
        let clipped = PaywallSafeAreaInsets.clipped(
            windowInsets: windowInsets,
            windowBounds: windowBounds,
            viewFrame: CGRect(x: 0, y: 103, width: 393, height: 749)
        )
        XCTAssertEqual(clipped, UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 0))
    }

    func testViewPartlyUnderStatusBarKeepsOnlyOverlap() {
        let clipped = PaywallSafeAreaInsets.clipped(
            windowInsets: windowInsets,
            windowBounds: windowBounds,
            viewFrame: CGRect(x: 0, y: 20, width: 393, height: 700)
        )
        XCTAssertEqual(clipped, UIEdgeInsets(top: 39, left: 0, bottom: 0, right: 0))
    }

    func testUpdateScriptIsGuardedAndCarriesAllSides() {
        let script = PaywallSafeAreaInsets.updateScript(UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0))
        XCTAssertTrue(script.contains("if (window.heliumUpdateSafeAreaInsets)"))
        XCTAssertTrue(script.contains("top: 59.0"))
        XCTAssertTrue(script.contains("bottom: 34.0"))
        XCTAssertTrue(script.contains("left: 0.0"))
        XCTAssertTrue(script.contains("right: 0.0"))
    }

    func testJsonObjectUsesBundleKeys() {
        let json = PaywallSafeAreaInsets.jsonObject(UIEdgeInsets(top: 59, left: 1, bottom: 34, right: 2))
        XCTAssertEqual(json, ["top": 59, "bottom": 34, "left": 1, "right": 2])
    }

    func testViewRelativeSafeAreaFlagParses() {
        let flags = HeliumFeatureFlags.from(JSON(["viewRelativeSafeArea": true]))
        XCTAssertTrue(flags.isEnabled(.viewRelativeSafeArea))
        XCTAssertFalse(HeliumFeatureFlags.empty.isEnabled(.viewRelativeSafeArea))
    }
}
