import QuartzCore

/// Keyed on the source event, not the `HeliumHaptic`: distinct events can share a haptic.
enum HapticThrottleKey: Hashable {
    case product(ProductHapticAction)
    case custom(String)
}

/// The first event for a key plays; repeats inside `window` are dropped, never delayed.
@MainActor
final class HapticThrottle {
    nonisolated static let defaultWindow: CFTimeInterval = 0.05

    private let window: CFTimeInterval
    private let now: () -> CFTimeInterval
    private var lastPlayedAt: [HapticThrottleKey: CFTimeInterval] = [:]

    init(
        window: CFTimeInterval = HapticThrottle.defaultWindow,
        now: @escaping () -> CFTimeInterval = { CACurrentMediaTime() }
    ) {
        self.window = window
        self.now = now
    }

    func tryAcquire(_ key: HapticThrottleKey) -> Bool {
        let timestamp = now()
        if let last = lastPlayedAt[key], timestamp - last < window { return false }
        lastPlayedAt[key] = timestamp
        return true
    }
}
