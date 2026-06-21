import XCTest
@testable import Helium

@MainActor
final class PaywallHapticsImplTests: XCTestCase {

    private final class FakeHapticPlayer: HapticPlayer {
        private(set) var played: [HeliumHaptic] = []
        func play(_ haptic: HeliumHaptic) { played.append(haptic) }
    }

    private func makeHaptics(
        enabled: Set<ProductHapticAction>
    ) -> (PaywallHapticsImpl, FakeHapticPlayer) {
        let player = FakeHapticPlayer()
        let haptics = PaywallHapticsImpl(player: player, enabledActions: { enabled })
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
        var enabled: Set<ProductHapticAction> = []
        let haptics = PaywallHapticsImpl(player: player, enabledActions: { enabled })

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
}
