import XCTest
@testable import Helium

/// Tests for boolean encoding through the type-erased `AnyCodable`/`AnyEncodable` path.
///
/// Background: encoding a boolean from a type-erased `Any` is ambiguous because Swift's
/// `NSNumber` bridging is lenient in both directions — a numeric `NSNumber(1)` casts to
/// `Bool` (== true), and a boolean `NSNumber`/`CFBoolean` casts to `Int` (== 1). Booleans
/// that originate outside pure Swift (JSONSerialization, Objective-C `@YES`/`@NO`, and
/// React Native / Expo / Flutter bridges) arrive as `CFBoolean` (`__NSCFBoolean`), and
/// must serialize as `true`/`false` — NOT `1`/`0`. Numeric `NSNumber`s must stay numeric.
///
/// This is the exact path used to inject `customPaywallTraits` into the paywall webview
/// (`HeliumUserTraits` → `JSONEncoder`), so a regression here silently corrupts boolean
/// traits such as `showOnlyPremium`.
final class AnyEncodableBooleanTests: XCTestCase {

    // MARK: - Helpers

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Encodes a single value (wrapped in a one-key object) and returns the JSON string.
    private func json(_ value: Any?) throws -> String {
        let data = try encoder.encode(["v": AnyCodable(value)])
        return String(decoding: data, as: UTF8.self)
    }

    /// Returns a genuine `CFBoolean` (`__NSCFBoolean`) — exactly what `JSONSerialization`,
    /// Objective-C, and cross-platform bridges produce for a boolean.
    private func cfBoolean(_ b: Bool) -> Any {
        let source = b ? #"{"v":true}"# : #"{"v":false}"#
        let obj = try! JSONSerialization.jsonObject(with: Data(source.utf8)) as! [String: Any]
        return obj["v"]!
    }

    /// True iff the reparsed JSON value is a JSON boolean (CFBoolean) rather than a number.
    /// `JSONSerialization` maps JSON `true` → CFBoolean and JSON `1` → numeric NSNumber,
    /// so this faithfully reflects which token was actually written.
    private func isJSONBoolean(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Encodes via the real trait path (`HeliumUserTraits` → `JSONEncoder`) and reparses.
    private func encodeTraitAndReparse(_ dict: [String: Any], key: String) throws -> Any? {
        let data = try encoder.encode(HeliumUserTraits(dict))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?[key]
    }

    // MARK: - Native Swift Bool

    func testNativeSwiftBoolEncodesAsBoolean() throws {
        XCTAssertEqual(try json(true), #"{"v":true}"#)
        XCTAssertEqual(try json(false), #"{"v":false}"#)
    }

    // MARK: - CFBoolean (JSONSerialization / bridges) — the regression under test

    func testCFBooleanEncodesAsBooleanNotInteger() throws {
        // This is the exact case that regressed: a boolean parsed by JSONSerialization
        // (an __NSCFBoolean) must serialize as true/false, not 1/0.
        XCTAssertEqual(try json(cfBoolean(true)), #"{"v":true}"#)
        XCTAssertEqual(try json(cfBoolean(false)), #"{"v":false}"#)
    }

    func testObjCNSNumberBoolEncodesAsBoolean() throws {
        // Objective-C `@YES` / `@NO` and `NSNumber(value: Bool)` are CFBoolean-backed.
        XCTAssertEqual(try json(NSNumber(value: true)), #"{"v":true}"#)
        XCTAssertEqual(try json(NSNumber(value: false)), #"{"v":false}"#)
    }

    // MARK: - Numeric NSNumber must NOT become boolean (preserves the original fix)

    func testNumericNSNumberZeroAndOneStayNumeric() throws {
        // These come from Expo/Flutter numeric bridging; they must NOT collapse to true/false.
        XCTAssertEqual(try json(NSNumber(value: 1)), #"{"v":1}"#)
        XCTAssertEqual(try json(NSNumber(value: 0)), #"{"v":0}"#)
    }

    func testNumericNSNumberFromJSONStaysNumeric() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(#"{"v":1}"#.utf8)) as! [String: Any]
        XCTAssertEqual(try json(obj["v"]!), #"{"v":1}"#)
    }

    func testNumericNSNumberDoubleStaysNumeric() throws {
        // A non-integral numeric NSNumber must remain a number.
        let v = try json(NSNumber(value: 1.5))
        XCTAssertFalse(v.contains("true"))
        XCTAssertFalse(v.contains("false"))
        XCTAssertTrue(v.contains("1.5"))
    }

    // MARK: - Other scalars unaffected

    func testIntStringDoubleUnaffected() throws {
        XCTAssertEqual(try json(42), #"{"v":42}"#)
        XCTAssertEqual(try json(-7), #"{"v":-7}"#)
        XCTAssertEqual(try json("hello"), #"{"v":"hello"}"#)
        XCTAssertEqual(try json(Int64(9_000_000_000)), #"{"v":9000000000}"#)
    }

    // MARK: - HeliumUserTraits round-trip (the real injection path)

    func testTraitBooleanFromJSONSerializesAsBoolean() throws {
        // Mirrors the demo app / cross-platform bridge: traits built from parsed JSON.
        let parsed = try JSONSerialization.jsonObject(
            with: Data(#"{"showOnlyPremium": true}"#.utf8)) as! [String: Any]

        let value = try encodeTraitAndReparse(parsed, key: "showOnlyPremium")
        XCTAssertTrue(isJSONBoolean(value), "showOnlyPremium must serialize as a JSON boolean, not a number")
        XCTAssertEqual(value as? Bool, true)
    }

    func testTraitNativeBooleanSerializesAsBoolean() throws {
        let value = try encodeTraitAndReparse(["showOnlyPremium": true], key: "showOnlyPremium")
        XCTAssertTrue(isJSONBoolean(value))
        XCTAssertEqual(value as? Bool, true)
    }

    func testTraitNumericValueStaysNumeric() throws {
        let parsed = try JSONSerialization.jsonObject(
            with: Data(#"{"count": 1}"#.utf8)) as! [String: Any]

        let value = try encodeTraitAndReparse(parsed, key: "count")
        XCTAssertFalse(isJSONBoolean(value), "numeric trait must not collapse to a boolean")
        XCTAssertEqual(value as? Int, 1)
    }

    func testMixedTraitsPreserveTypesTogether() throws {
        // A single payload mixing genuine booleans and numeric 0/1 — the crux of the
        // ambiguity. Booleans stay boolean; numbers stay numeric.
        let parsed = try JSONSerialization.jsonObject(
            with: Data(#"{"flagOn": true, "flagOff": false, "count": 1, "zero": 0}"#.utf8)) as! [String: Any]

        let flagOn = try encodeTraitAndReparse(parsed, key: "flagOn")
        let flagOff = try encodeTraitAndReparse(parsed, key: "flagOff")
        let count = try encodeTraitAndReparse(parsed, key: "count")
        let zero = try encodeTraitAndReparse(parsed, key: "zero")

        XCTAssertTrue(isJSONBoolean(flagOn));  XCTAssertEqual(flagOn as? Bool, true)
        XCTAssertTrue(isJSONBoolean(flagOff)); XCTAssertEqual(flagOff as? Bool, false)
        XCTAssertFalse(isJSONBoolean(count));  XCTAssertEqual(count as? Int, 1)
        XCTAssertFalse(isJSONBoolean(zero));   XCTAssertEqual(zero as? Int, 0)
    }

    func testNestedBooleanInDictionaryAndArray() throws {
        // Booleans nested inside container traits must also survive.
        let parsed = try JSONSerialization.jsonObject(
            with: Data(#"{"nested": {"on": true}, "list": [true, false, 1]}"#.utf8)) as! [String: Any]

        let data = try encoder.encode(HeliumUserTraits(parsed))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let nested = obj["nested"] as? [String: Any]
        XCTAssertTrue(isJSONBoolean(nested?["on"]))
        XCTAssertEqual(nested?["on"] as? Bool, true)

        let list = obj["list"] as? [Any]
        XCTAssertEqual(list?.count, 3)
        XCTAssertTrue(isJSONBoolean(list?[0]));  XCTAssertEqual(list?[0] as? Bool, true)
        XCTAssertTrue(isJSONBoolean(list?[1]));  XCTAssertEqual(list?[1] as? Bool, false)
        XCTAssertFalse(isJSONBoolean(list?[2])); XCTAssertEqual(list?[2] as? Int, 1)
    }
}
