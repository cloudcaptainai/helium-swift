import XCTest
@testable import Helium

@MainActor
final class PaywallHapticsImplTests: XCTestCase {

    private final class FakeHapticPlayer: HapticPlayer {
        private(set) var played: [HeliumHaptic] = []
        func play(_ haptic: HeliumHaptic) { played.append(haptic) }
    }

    private final class Clock {
        var now: CFTimeInterval = 0
    }

    private func makeHaptics(
        enabled: Set<ProductHapticAction>,
        clock: Clock? = nil
    ) -> (PaywallHapticsImpl, FakeHapticPlayer) {
        let clock = clock ?? Clock()
        let player = FakeHapticPlayer()
        let haptics = PaywallHapticsImpl(
            player: player,
            enabledActions: { enabled },
            throttle: HapticThrottle(window: 1, now: { clock.now })
        )
        return (haptics, player)
    }

    // MARK: - Product events are gated by enabled actions

    func test_GIVEN_actionEnabled_WHEN_productSelected_THEN_playsSelection() {
        let (haptics, player) = makeHaptics(enabled: [.select])
        haptics.onProductSelected()
        XCTAssertEqual(player.played, [.selection])
    }

    func test_GIVEN_actionDisabled_WHEN_productSelected_THEN_playsNothing() {
        let (haptics, player) = makeHaptics(enabled: [])
        haptics.onProductSelected()
        XCTAssertTrue(player.played.isEmpty)
    }

    func test_GIVEN_allActionsEnabled_WHEN_purchaseLifecycle_THEN_playsMappedHaptics() {
        let (haptics, player) = makeHaptics(enabled: Set(ProductHapticAction.allCases))
        haptics.onPurchasePressed()
        haptics.onPurchaseSucceeded()
        haptics.onPurchaseCancelled()
        haptics.onPurchaseFailed()
        XCTAssertEqual(player.played, [.success, .success, .warning, .error])
    }

    func test_GIVEN_onlyPressEnabled_WHEN_pressedThenSucceeded_THEN_playsOnlyPress() {
        let (haptics, player) = makeHaptics(enabled: [.press])
        haptics.onPurchasePressed()
        haptics.onPurchaseSucceeded()
        XCTAssertEqual(player.played, [.success])
    }

    // MARK: - Enabled actions are re-read on every event

    func test_GIVEN_enabledActionsChange_WHEN_productSelected_THEN_reflectsLatest() {
        let player = FakeHapticPlayer()
        let clock = Clock()
        var enabled: Set<ProductHapticAction> = []
        let haptics = PaywallHapticsImpl(
            player: player,
            enabledActions: { enabled },
            throttle: HapticThrottle(window: 1, now: { clock.now })
        )

        haptics.onProductSelected()
        XCTAssertTrue(player.played.isEmpty)

        enabled = [.select]
        haptics.onProductSelected()
        XCTAssertEqual(player.played, [.selection])
    }

    // MARK: - Custom haptics are ungated and map strings to haptics

    func test_GIVEN_knownCustomValues_WHEN_onCustomHaptic_THEN_playsMappedHaptics() {
        let (haptics, player) = makeHaptics(enabled: [])
        haptics.onCustomHaptic("selection")
        haptics.onCustomHaptic("success")
        haptics.onCustomHaptic("cancel")
        haptics.onCustomHaptic("failure")
        XCTAssertEqual(player.played, [.selection, .success, .warning, .error])
    }

    func test_GIVEN_nilCustomValue_WHEN_onCustomHaptic_THEN_playsNothing() {
        let (haptics, player) = makeHaptics(enabled: [])
        haptics.onCustomHaptic(nil)
        XCTAssertTrue(player.played.isEmpty)
    }

    func test_GIVEN_unknownCustomValue_WHEN_onCustomHaptic_THEN_playsNothing() {
        let (haptics, player) = makeHaptics(enabled: [])
        haptics.onCustomHaptic("explode")
        haptics.onCustomHaptic("")
        XCTAssertTrue(player.played.isEmpty)
    }

    // MARK: - Repeats of one event are throttled, distinct events are not

    func test_GIVEN_pressAndSuccessEnabled_WHEN_pressedThenSucceededWithinWindow_THEN_bothPlay() {
        let (haptics, player) = makeHaptics(enabled: [.press, .success])

        haptics.onPurchasePressed()
        haptics.onPurchaseSucceeded()

        XCTAssertEqual(player.played, [.success, .success])
    }

    func test_GIVEN_selectEnabled_WHEN_selectedTwiceWithinWindow_THEN_playsOnce() {
        let clock = Clock()
        let (haptics, player) = makeHaptics(enabled: [.select], clock: clock)

        haptics.onProductSelected()
        clock.now = 0.999
        haptics.onProductSelected()

        XCTAssertEqual(player.played, [.selection])
    }

    func test_GIVEN_selectEnabled_WHEN_selectedTwiceAfterWindow_THEN_playsTwice() {
        let clock = Clock()
        let (haptics, player) = makeHaptics(enabled: [.select], clock: clock)

        haptics.onProductSelected()
        clock.now = 1
        haptics.onProductSelected()

        XCTAssertEqual(player.played, [.selection, .selection])
    }

    func test_GIVEN_sameCustomValue_WHEN_playedTwiceWithinWindow_THEN_playsOnce() {
        let (haptics, player) = makeHaptics(enabled: [])

        haptics.onCustomHaptic("success")
        haptics.onCustomHaptic("success")

        XCTAssertEqual(player.played, [.success])
    }

    func test_GIVEN_customSuccessAndProductSuccess_WHEN_withinWindow_THEN_bothPlay() {
        let (haptics, player) = makeHaptics(enabled: [.success])

        haptics.onPurchaseSucceeded()
        haptics.onCustomHaptic("success")

        XCTAssertEqual(player.played, [.success, .success])
    }

    func test_GIVEN_selectDisabled_WHEN_selectedTwiceThenEnabled_THEN_stillPlays() {
        let player = FakeHapticPlayer()
        let clock = Clock()
        var enabled: Set<ProductHapticAction> = []
        let haptics = PaywallHapticsImpl(
            player: player,
            enabledActions: { enabled },
            throttle: HapticThrottle(window: 1, now: { clock.now })
        )

        haptics.onProductSelected()
        haptics.onProductSelected()
        XCTAssertTrue(player.played.isEmpty)

        enabled = [.select]
        haptics.onProductSelected()

        XCTAssertEqual(player.played, [.selection])
    }

    func test_GIVEN_unknownCustomValue_WHEN_onCustomHaptic_THEN_clockIsNeverRead() {
        let player = FakeHapticPlayer()
        var reads = 0
        let haptics = PaywallHapticsImpl(
            player: player,
            enabledActions: { [] },
            throttle: HapticThrottle(now: { reads += 1; return 0 })
        )

        haptics.onCustomHaptic("explode")

        XCTAssertEqual(reads, 0)
        XCTAssertTrue(player.played.isEmpty)
    }
}
