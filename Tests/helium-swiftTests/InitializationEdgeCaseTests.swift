import XCTest
@testable import Helium

final class InitializationEdgeCaseTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Helium.resetHelium()
    }

    override func tearDown() {
        Helium.resetHelium()
        super.tearDown()
    }

    func testPresentBeforeInitializeReturnsNotInitialized() {
        // Don't initialize - call upsellViewResultFor directly
        let result = Helium.shared.upsellViewResultFor(
            trigger: "test_trigger",
            presentationContext: PaywallPresentationContext.empty
        )
        XCTAssertNil(result.viewAndSession)
        XCTAssertEqual(result.fallbackReason, .notInitialized)
    }

    func testClearAllCachedStateResetsStatus() {
        // Inject config to simulate download success
        let config = makeTestConfig(triggers: ["t": makeTestPaywallInfo()])
        injectConfig(config)
        XCTAssertEqual(Helium.shared.getDownloadStatus(), .downloadSuccess)

        Helium.shared.clearAllCachedState()
        XCTAssertEqual(Helium.shared.getDownloadStatus(), .notDownloadedYet)
    }

    func testPaywallsLoadedReturnsFalseBeforeDownload() {
        // After reset, no paywalls loaded
        XCTAssertFalse(Helium.shared.paywallsLoaded())
    }

    func testGetDownloadStatusAfterReset() {
        Helium.resetHelium()
        XCTAssertEqual(Helium.shared.getDownloadStatus(), .notDownloadedYet)
    }

    func testIsInitializedReturnsFalseAfterReset() {
        XCTAssertFalse(Helium.shared.isInitialized())
    }
}
