import XCTest
@testable import Helium

final class ObservabilitySamplingTests: XCTestCase {
    private let bucketZero = "6B4A5B7E-1F2D-4C3B-9A8E-000000000000"
    private let bucket200 = "6B4A5B7E-1F2D-4C3B-9A8E-0000000000C8"
    private let bucket9999 = "6B4A5B7E-1F2D-4C3B-9A8E-00000000270F"

    func testRateZeroSelectsNobodyAndRateOneSelectsEveryone() {
        XCTAssertFalse(ObservabilitySampling.isSelected(persistentId: bucketZero, rate: 0))
        XCTAssertTrue(ObservabilitySampling.isSelected(persistentId: bucket9999, rate: 1))
    }

    func testSelectionUsesTheLastEightHexDigitsOfThePersistentId() {
        XCTAssertTrue(ObservabilitySampling.isSelected(persistentId: bucketZero, rate: 0.02))
        XCTAssertFalse(ObservabilitySampling.isSelected(persistentId: bucket200, rate: 0.02))
        XCTAssertFalse(ObservabilitySampling.isSelected(persistentId: bucket9999, rate: 0.02))
    }

    func testRaisingTheRateKeepsAlreadySelectedDevices() {
        XCTAssertTrue(ObservabilitySampling.isSelected(persistentId: bucketZero, rate: 0.05))
        XCTAssertTrue(ObservabilitySampling.isSelected(persistentId: bucket200, rate: 0.05))
    }

    func testSelectionIsStableForTheSameId() {
        let id = UUID().uuidString
        XCTAssertEqual(
            ObservabilitySampling.isSelected(persistentId: id, rate: 0.02),
            ObservabilitySampling.isSelected(persistentId: id, rate: 0.02)
        )
    }

    func testNonProductionBuildsAreAlwaysIncluded() {
        XCTAssertTrue(ObservabilitySampling.includesThisDevice(rate: 0.02, isProduction: false, persistentId: bucket9999))
    }

    func testProductionBuildsFollowTheBucket() {
        XCTAssertTrue(ObservabilitySampling.includesThisDevice(rate: 0.02, isProduction: true, persistentId: bucketZero))
        XCTAssertFalse(ObservabilitySampling.includesThisDevice(rate: 0.02, isProduction: true, persistentId: bucket9999))
    }
}
