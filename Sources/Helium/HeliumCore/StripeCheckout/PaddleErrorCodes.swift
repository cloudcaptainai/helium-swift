import Foundation

/// Hierarchy: `restorableCodes ⊂ prefetchAlreadyEntitledCodes`.
/// Restorable codes resolve SDK-side as restored; non-restorable
/// alreadyEntitled codes are routed through the bundle's failure UX.
enum PaddleErrorCodes {

    static let prefetchAlreadyEntitledCodes: Set<String> = [
        "duplicate_subscription",
        "trial_already_used",
    ]

    static let restorableCodes: Set<String> = [
        "duplicate_subscription",
    ]

    static func isPrefetchAlreadyEntitled(_ code: String) -> Bool {
        prefetchAlreadyEntitledCodes.contains(code)
    }

    static func isRestorable(_ code: String) -> Bool {
        restorableCodes.contains(code)
    }

    static func defaultMessage(for code: String) -> String {
        switch code {
        case "trial_already_used":
            return "You've already used your free trial for this product."
        default:
            return "You already have an active subscription for this product."
        }
    }
}
