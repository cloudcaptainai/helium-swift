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
}
