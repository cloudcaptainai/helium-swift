import XCTest
@testable import Helium

final class InitializationEdgeCaseTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        Helium.resetHelium()
    }

    override func tearDown() {
        Helium.resetHelium()
        super.tearDown()
    }

    func testSkipPaywallBeforeInitializeReturnsFalse() {
        // Without initialization or config, skipPaywallIfNeeded should safely return false
        let skipped = Helium.shared.skipPaywallIfNeeded(
            trigger: "test_trigger",
            presentationContext: .empty
        )
        XCTAssertFalse(skipped)
    }

    func testPaywallsLoadedReturnsFalseBeforeDownload() {
        // After reset, no paywalls loaded
        XCTAssertFalse(Helium.shared.paywallsLoaded())
    }

    func testGetDownloadStatusAfterReset() {
        XCTAssertEqual(Helium.shared.getDownloadStatus(), .notDownloadedYet)
    }

    func testIsInitializedReturnsFalseAfterReset() {
        XCTAssertFalse(Helium.shared.isInitialized())
    }
}
