import XCTest
@testable import Helium

final class SdkApiCallTrackerTests: XCTestCase {

    func testSamplingEmitsTheFirstTwentyCallsThenPowersOfTwo() {
        let emitted = (1...70).filter { SdkApiCallTracker.shouldEmit(callCount: $0) }

        XCTAssertEqual(emitted, Array(1...20) + [32, 64])
    }

    func testRecordIncrementsTheIndexAcrossMethodsAndTheCountPerMethod() {
        let tracker = SdkApiCallTracker()

        let first = tracker.record(.initialize)
        let second = tracker.record(.presentPaywall)
        let third = tracker.record(.presentPaywall)

        XCTAssertEqual([first.apiCallIndex, second.apiCallIndex, third.apiCallIndex], [1, 2, 3])
        XCTAssertEqual([first.callCountForMethod, second.callCountForMethod, third.callCountForMethod], [1, 1, 2])
    }

    func testProductionBuildsRecordNothing() {
        let tracker = SdkApiCallTracker()

        trackSdkApiCall(.hidePaywall, isProduction: true, tracker: tracker)

        XCTAssertEqual(tracker.record(.hidePaywall).apiCallIndex, 1)
    }

    func testNonProductionBuildsRecordTheCall() {
        let tracker = SdkApiCallTracker()

        trackSdkApiCall(.hidePaywall, isProduction: false, tracker: tracker)

        XCTAssertEqual(tracker.record(.hidePaywall).apiCallIndex, 2)
    }

    func testMarkInitializedCountsAndResetOnlyClearsTiming() {
        let tracker = SdkApiCallTracker()
        XCTAssertEqual(tracker.initializeCount, 0)
        XCTAssertNil(tracker.msSinceInitialize)

        tracker.markInitialized()
        XCTAssertEqual(tracker.initializeCount, 1)
        XCTAssertNotNil(tracker.msSinceInitialize)

        tracker.markReset()
        XCTAssertNil(tracker.msSinceInitialize)
        XCTAssertEqual(tracker.initializeCount, 1)
    }
}
