import XCTest
@testable import Helium

/// Mirrors the Android SDK's flag semantics: strict boolean coercion, undeclared
/// keys ignored, and every flag off unless the server sends `true`.
final class HeliumFeatureFlagsTests: XCTestCase {

    func testTrueBooleanEnablesTheFlag() {
        let flags = HeliumFeatureFlags.from(JSON(["jsCrashFallback": true]))

        XCTAssertTrue(flags.isEnabled(.jsCrashFallback))
    }

    func testFalseBooleanDisablesTheFlag() {
        let flags = HeliumFeatureFlags.from(JSON(["jsCrashFallback": false]))

        XCTAssertFalse(flags.isEnabled(.jsCrashFallback))
    }

    func testAbsentKeyIsOff() {
        let flags = HeliumFeatureFlags.from(JSON(["someOtherKey": true]))

        XCTAssertFalse(flags.isEnabled(.jsCrashFallback))
    }

    func testStringTrueIsRejectedAndStaysOff() {
        let flags = HeliumFeatureFlags.from(JSON(["jsCrashFallback": "true"]))

        XCTAssertFalse(flags.isEnabled(.jsCrashFallback))
    }

    func testNumericValueIsRejectedAndStaysOff() {
        let flags = HeliumFeatureFlags.from(JSON(["jsCrashFallback": 1]))

        XCTAssertFalse(flags.isEnabled(.jsCrashFallback))
    }

    func testNilMapMeansEveryFlagIsOff() {
        let flags = HeliumFeatureFlags.from(nil)

        for flag in HeliumFeatureFlag.allCases {
            XCTAssertFalse(flags.isEnabled(flag))
        }
    }

    func testEmptyMeansEveryFlagIsOff() {
        for flag in HeliumFeatureFlag.allCases {
            XCTAssertFalse(HeliumFeatureFlags.empty.isEnabled(flag))
        }
    }
}
