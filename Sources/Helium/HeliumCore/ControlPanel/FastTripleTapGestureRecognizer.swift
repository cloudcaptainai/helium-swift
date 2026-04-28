import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Triple-tap recognizer with a tighter inter-tap window than UIKit's default,
/// used to gate access to the Helium control panel and reduce accidental triggers.
final class FastTripleTapGestureRecognizer: UIGestureRecognizer {
    private let requiredTaps: Int
    private let maxIntervalBetweenTaps: CFTimeInterval
    private let maxMovement: CGFloat

    private var tapCount: Int = 0
    private var lastTapEndTime: CFTimeInterval = 0
    private var startLocation: CGPoint = .zero
    private var staleTimer: Timer?

    init(
        target: Any?,
        action: Selector?,
        requiredTaps: Int = 3,
        maxIntervalBetweenTaps: CFTimeInterval = 0.25,
        maxMovement: CGFloat = 20
    ) {
        self.requiredTaps = requiredTaps
        self.maxIntervalBetweenTaps = maxIntervalBetweenTaps
        self.maxMovement = maxMovement
        super.init(target: target, action: action)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first else {
            state = .failed
            return
        }
        startLocation = touch.location(in: view)
        let now = CACurrentMediaTime()
        if tapCount > 0 && now - lastTapEndTime > maxIntervalBetweenTaps {
            tapCount = 0
        }
        invalidateStaleTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: view)
        let dx = location.x - startLocation.x
        let dy = location.y - startLocation.y
        if (dx * dx + dy * dy) > maxMovement * maxMovement {
            state = .failed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        let now = CACurrentMediaTime()
        if tapCount > 0 && now - lastTapEndTime > maxIntervalBetweenTaps {
            tapCount = 0
        }
        tapCount += 1
        lastTapEndTime = now

        if tapCount >= requiredTaps {
            state = .recognized
        } else {
            scheduleStaleReset()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func reset() {
        super.reset()
        tapCount = 0
        invalidateStaleTimer()
    }

    private func invalidateStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = nil
    }

    private func scheduleStaleReset() {
        invalidateStaleTimer()
        staleTimer = Timer.scheduledTimer(withTimeInterval: maxIntervalBetweenTaps, repeats: false) { [weak self] _ in
            self?.tapCount = 0
            self?.staleTimer = nil
        }
    }
}
