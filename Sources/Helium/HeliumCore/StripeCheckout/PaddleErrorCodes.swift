import Foundation

/// Allow-lists and message helpers for bandit's Paddle 409 error codes.
///
/// Mirrors the bundler-side equivalents in
/// `bundler-service/server/heliumStandalonePaddle.ts` —
/// `routePaddle409` (success/failure routing) and `parsePaddle409`
/// (default UX strings). Both sides must update together when a new
/// Paddle 409 code is added.
///
/// Hierarchy:
///
///   restorableCodes ⊂ prefetchAlreadyEntitledCodes
///
/// - Membership in `prefetchAlreadyEntitledCodes` means "the SDK
///   pre-fetch surfaces this 409 as `PaddlePrefetchError.alreadyEntitled`
///   so the bundle can short-circuit on click instead of live-fetching."
/// - Membership in `restorableCodes` further means "the SDK can
///   short-circuit before opening the bundle and fire
///   `PurchaseRestoredEvent` directly." Codes outside this subset are
///   alreadyEntitled-class but route to a failure UX in the bundle
///   (e.g. `trial_already_used` → entitled_failure → paymentFailureUrl)
///   — the SDK opens the bundle for those and lets the bundle's
///   existing routing handle it.
enum PaddleErrorCodes {

    /// Codes the SDK pre-fetch surfaces as `PaddlePrefetchError.alreadyEntitled`.
    /// Mirrors the bundler's `parsePaddle409` known codes.
    static let prefetchAlreadyEntitledCodes: Set<String> = [
        "duplicate_subscription",
        "trial_already_used",
    ]

    /// Subset of `prefetchAlreadyEntitledCodes` that route to the
    /// "user owns this, fire restored" UX. Mirrors the bundler's
    /// `routePaddle409` → `'success'` branch.
    static let restorableCodes: Set<String> = [
        "duplicate_subscription",
    ]

    /// True when the SDK should surface this 409 as
    /// `PaddlePrefetchError.alreadyEntitled` in pre-fetch (vs. falling
    /// through to a generic server error).
    static func isPrefetchAlreadyEntitled(_ code: String) -> Bool {
        prefetchAlreadyEntitledCodes.contains(code)
    }

    /// True when this code's UX is "user owns this, fire restored."
    /// Drives `PaddleCheckoutPrefetchCoordinator.tappedShortCircuit`'s
    /// decision to skip Safari and fire `PurchaseRestoredEvent` directly.
    static func isRestorable(_ code: String) -> Bool {
        restorableCodes.contains(code)
    }

    /// Default user-facing message per code. Used when bandit's 409 body
    /// doesn't include a `detail` field. Mirrors the bundler's
    /// `parsePaddle409` defaults (`DEFAULT_MESSAGE` and
    /// `TRIAL_USED_MESSAGE`) so the SDK-fired and bundle-fired UX
    /// strings stay consistent.
    static func defaultMessage(for code: String) -> String {
        switch code {
        case "trial_already_used":
            return "You've already used your free trial for this product."
        default:
            return "You already have an active subscription for this product."
        }
    }
}
