import UIKit

/// Feedback generators honor the user's system haptic settings and need no permission, so there
/// is nothing to request or gate here. A fresh generator per call keeps this stateless; at paywall
/// interaction rates the Taptic Engine warm-up that caching one would save is immaterial.
@MainActor
final class UIKitHapticPlayer: HapticPlayer {
    func play(_ haptic: HeliumHaptic) {
        switch haptic {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
