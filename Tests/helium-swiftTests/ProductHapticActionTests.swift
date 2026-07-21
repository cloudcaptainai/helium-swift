import XCTest
@testable import Helium

final class ProductHapticActionTests: XCTestCase {

    func test_GIVEN_knownConfigKeys_WHEN_from_THEN_resolvesMatchingActions() {
        let actions = ProductHapticAction.from(["select", "press", "success", "cancel", "fail"])
        XCTAssertEqual(actions, Set(ProductHapticAction.allCases))
    }

    func test_GIVEN_unknownConfigKeys_WHEN_from_THEN_ignoresThem() {
        let actions = ProductHapticAction.from(["select", "bogus", "tap"])
        XCTAssertEqual(actions, [.select])
    }

    func test_GIVEN_duplicateConfigKeys_WHEN_from_THEN_dedupes() {
        let actions = ProductHapticAction.from(["press", "press", "press"])
        XCTAssertEqual(actions, [.press])
    }

    func test_GIVEN_emptyConfigKeys_WHEN_from_THEN_returnsEmptySet() {
        XCTAssertTrue(ProductHapticAction.from([]).isEmpty)
    }

    func test_GIVEN_action_WHEN_readingConfigKey_THEN_matchesWireValue() {
        XCTAssertEqual(ProductHapticAction.select.configKey, "select")
        XCTAssertEqual(ProductHapticAction.press.configKey, "press")
        XCTAssertEqual(ProductHapticAction.success.configKey, "success")
        XCTAssertEqual(ProductHapticAction.cancel.configKey, "cancel")
        XCTAssertEqual(ProductHapticAction.fail.configKey, "fail")
    }

    func test_GIVEN_action_WHEN_readingHaptic_THEN_matchesMapping() {
        XCTAssertEqual(ProductHapticAction.select.haptic, .selection)
        XCTAssertEqual(ProductHapticAction.press.haptic, .success)
        XCTAssertEqual(ProductHapticAction.success.haptic, .success)
        XCTAssertEqual(ProductHapticAction.cancel.haptic, .warning)
        XCTAssertEqual(ProductHapticAction.fail.haptic, .error)
    }
}
