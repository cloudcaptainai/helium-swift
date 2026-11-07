import XCTest
import UIKit
@testable import Helium

final class PaywallSafeAreaInsetsTests: XCTestCase {

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

}
