/// Product-flow haptics fire only for events the paywall has enabled; a custom haptic is requested
/// explicitly per action and bypasses that gating.
@MainActor
protocol PaywallHaptics {
    func onProductSelected()
    func onPurchasePressed()
    func onPurchaseSucceeded()
    func onPurchaseCancelled()
    func onPurchaseFailed()
    func onCustomHaptic(_ value: String?)
}

@MainActor
final class PaywallHapticsImpl: PaywallHaptics {
    /// Param key a paywall sets on a custom action to request a haptic by name.
    static let customHapticParam = "hlm_haptic"

    private let player: HapticPlayer
    /// Re-read on every event so haptics resolve against whichever paywall is currently presented.
    private let enabledActions: () -> Set<ProductHapticAction>

    init(player: HapticPlayer, enabledActions: @escaping () -> Set<ProductHapticAction>) {
        self.player = player
        self.enabledActions = enabledActions
    }

    func onProductSelected() { playGated(.select) }
    func onPurchasePressed() { playGated(.press) }
    func onPurchaseSucceeded() { playGated(.success) }
    func onPurchaseCancelled() { playGated(.cancel) }
    func onPurchaseFailed() { playGated(.fail) }

    func onCustomHaptic(_ value: String?) {
        guard let value, let haptic = customHaptic(for: value) else { return }
        player.play(haptic)
    }

    private func playGated(_ action: ProductHapticAction) {
        if enabledActions().contains(action) {
            player.play(action.haptic)
        }
    }

    private func customHaptic(for value: String) -> HeliumHaptic? {
        switch value {
        case "selection": return .selection
        case "success": return .success
        case "cancel": return .warning
        case "failure": return .error
        default: return nil
        }
    }
}
