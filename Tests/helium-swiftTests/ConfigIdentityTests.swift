import XCTest
@testable import Helium

final class ConfigIdentityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        Helium.resetHelium(clearUserTraits: true)
    }

    override func tearDown() {
        Helium.resetHelium(clearUserTraits: true)
        super.tearDown()
    }

    func testSetCustomUserId() {
        Helium.identify.userId = "custom_user_123"
        XCTAssertEqual(Helium.identify.userId, "custom_user_123")
    }

    func testSetUserTraits() {
        let traits = HeliumUserTraits(["plan": "premium", "age": 25, "active": true])
        Helium.identify.setUserTraits(traits)

        let retrieved = Helium.identify.getUserTraits()
        XCTAssertEqual(retrieved["plan"] as? String, "premium")
        XCTAssertEqual(retrieved["age"] as? Int, 25)
        XCTAssertEqual(retrieved["active"] as? Bool, true)
    }

    func testAddUserTraitsMerges() {
        let initial = HeliumUserTraits(["plan": "free"])
        Helium.identify.setUserTraits(initial)

        let additional = HeliumUserTraits(["region": "US", "score": 100])
        Helium.identify.addUserTraits(additional)

        let retrieved = Helium.identify.getUserTraits()
        XCTAssertEqual(retrieved["plan"] as? String, "free")
        XCTAssertEqual(retrieved["region"] as? String, "US")
        XCTAssertEqual(retrieved["score"] as? Int, 100)
    }

    func testResetHeliumClearsUserTraits() {
        let traits = HeliumUserTraits(["plan": "premium"])
        Helium.identify.setUserTraits(traits)
        XCTAssertFalse(Helium.identify.getUserTraits().isEmpty)

        Helium.resetHelium(clearUserTraits: true)
        XCTAssertTrue(Helium.identify.getUserTraits().isEmpty)
    }

    func testResetHeliumPreservesUserTraitsWhenFlagFalse() {
        let traits = HeliumUserTraits(["plan": "premium"])
        Helium.identify.setUserTraits(traits)

        Helium.resetHelium(clearUserTraits: false)
        let retrieved = Helium.identify.getUserTraits()
        XCTAssertEqual(retrieved["plan"] as? String, "premium")
    }

    /// Regression test for an analytics-manager-queue crash reported by a customer:
    ///   `_dictionaryDownCast` → `objc_msgSend` while encoding `HeliumUserTraits` from
    ///   `HeliumAnalyticsManager.performIdentify`. Root cause is a data race on
    ///   `HeliumIdentityManager.heliumUserTraits`: writers (`setUserTraits` / `addUserTraits`)
    ///   run on caller threads while a reader on `com.helium.analyticsManager` copies the
    ///   struct via `getUserContext()` and encodes it. Unsynchronized struct reads of a
    ///   `Dictionary`-backed value type can tear the COW buffer pointer.
    ///
    /// The test reproduces the race by hammering writes on one queue and reads + encodes
    /// on another. Without synchronization this is expected to crash or throw within a few
    /// thousand iterations.
    func testConcurrentTraitsMutationAndEncodingIsThreadSafe() {
        let iterations = 5_000
        let writerDone = XCTestExpectation(description: "writer finished")
        let readerDone = XCTestExpectation(description: "reader finished")

        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<iterations {
                switch i % 4 {
                case 0:
                    Helium.identify.setUserTraits([
                        "plan": "premium",
                        "iteration": i,
                        "tags": ["a", "b", "c", "d"],
                        "nested": ["k1": "v1", "k2": i]
                    ])
                case 1:
                    Helium.identify.addUserTraits([
                        "key_\(i % 50)": "value_\(i)",
                        "score": i
                    ])
                case 2:
                    Helium.identify.setUserTraits(HeliumUserTraits([:]))
                default:
                    Helium.identify.addUserTraits([
                        "burst_\(i)": Array(repeating: i, count: 8)
                    ])
                }
            }
            writerDone.fulfill()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let encoder = JSONEncoder()
            for _ in 0..<iterations {
                let userContext = HeliumIdentityManager.shared.getUserContext()
                _ = try? encoder.encode(userContext)
            }
            readerDone.fulfill()
        }

        wait(for: [writerDone, readerDone], timeout: 60)
    }
}
