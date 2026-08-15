import XCTest
@testable import Helium

@MainActor
final class HapticThrottleTests: XCTestCase {

    private final class Clock {
        var now: CFTimeInterval = 0
    }

    private func makeThrottle() -> (HapticThrottle, Clock) {
        let clock = Clock()
        return (HapticThrottle(window: 1, now: { clock.now }), clock)
    }

    // MARK: - Window boundaries

    func test_GIVEN_freshThrottle_WHEN_tryAcquire_THEN_allows() {
        let (throttle, _) = makeThrottle()
        XCTAssertTrue(throttle.tryAcquire(.product(.select)))
    }

    func test_GIVEN_keyJustAcquired_WHEN_tryAcquireInsideWindow_THEN_denies() {
        let (throttle, clock) = makeThrottle()
        _ = throttle.tryAcquire(.product(.select))

        clock.now = 0.999

        XCTAssertFalse(throttle.tryAcquire(.product(.select)))
    }

    func test_GIVEN_keyAcquired_WHEN_windowElapsedExactly_THEN_allows() {
        let (throttle, clock) = makeThrottle()
        _ = throttle.tryAcquire(.product(.select))

        clock.now = 1

        XCTAssertTrue(throttle.tryAcquire(.product(.select)))
    }

    func test_GIVEN_acquireDeniedMidWindow_WHEN_windowElapsesFromFirstAccept_THEN_allows() {
        let (throttle, clock) = makeThrottle()
        _ = throttle.tryAcquire(.product(.select))

        clock.now = 0.5
        XCTAssertFalse(throttle.tryAcquire(.product(.select)))

        clock.now = 1
        XCTAssertTrue(throttle.tryAcquire(.product(.select)))
    }

    // MARK: - Keys do not share buckets

    func test_GIVEN_pressAcquired_WHEN_successAcquiredSameInstant_THEN_bothAllowed() {
        let (throttle, _) = makeThrottle()

        XCTAssertTrue(throttle.tryAcquire(.product(.press)))
        XCTAssertTrue(throttle.tryAcquire(.product(.success)))
    }

    func test_GIVEN_productSuccessAcquired_WHEN_customSuccessAcquiredSameInstant_THEN_bothAllowed() {
        let (throttle, _) = makeThrottle()

        XCTAssertTrue(throttle.tryAcquire(.product(.success)))
        XCTAssertTrue(throttle.tryAcquire(.custom("success")))
    }

    func test_GIVEN_differentCustomValues_WHEN_acquiredSameInstant_THEN_bothAllowed() {
        let (throttle, _) = makeThrottle()

        XCTAssertTrue(throttle.tryAcquire(.custom("selection")))
        XCTAssertTrue(throttle.tryAcquire(.custom("success")))
    }

    // MARK: - The default window is a cross SDK parity value

    func test_GIVEN_defaultWindow_WHEN_read_THEN_is50Milliseconds() {
        XCTAssertEqual(HapticThrottle.defaultWindow, 0.05, accuracy: 0.0001)
    }
}
