import Foundation

/// Outcomes the prefetch coordinator can produce for a given priceId.
///
/// Stage 5 (the click handler in ExternalWebCheckoutManager) pattern-matches
/// on these to decide what to do when the user taps Subscribe:
///   * `.ready` → embed both responses in `ctx.paddleBootstrap` and open Safari
///   * `.alreadyEntitled` → skip Safari, fire `purchase_already_entitled`,
///     return `.preCheckResolved` (Option A from HEL-5326)
///   * `.failed` → open Safari WITHOUT `ctx.paddleBootstrap`; the bundle
///     does its own fetch (current behavior, no regression)
///   * `.notStarted` → no prefetch was ever scheduled for this priceId
///     (paywall didn't have it, or was dismissed before prefetch ran).
///     Same default path as `.failed`.
/// One-shot resume guard for `withCheckedContinuation` races. Two observer
/// Tasks attempt to resume the continuation; only the first to call
/// `tryResume()` wins. Used by `awaitOutcome` to race the cached prefetch
/// Task against a timeout — the continuation must resume exactly once,
/// regardless of which Task gets there first.
///
/// `@unchecked Sendable` because the lock provides the synchronization
/// the compiler can't verify on its own. The one mutable field
/// (`resumed`) is only ever touched while the lock is held.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

/// Surfaced as the `Error` value of a `.failed` outcome when
/// `awaitOutcome` exceeds its timeout budget. Carries the priceId and
/// the budget so logs can correlate the timeout with which prefetch
/// stalled.
struct PaddlePrefetchAwaitTimeout: LocalizedError {
    let priceId: String
    let timeout: TimeInterval

    var errorDescription: String? {
        return "Paddle prefetch await timed out after \(timeout)s for priceId \(priceId)"
    }
}

enum PaddlePrefetchOutcome {
    case ready(
        bandit: PaddleCreateTransactionForPaywallResponse,
        paddle: PaddleTransactionCheckoutResult
    )
    case alreadyEntitled(code: String, message: String)
    case failed(error: Error)
    case notStarted
}

/// Coordinates the SDK pre-fetch chain (HEL-5326): runs bandit + Paddle BFF
/// in parallel per priceId during in-app paywall presentation, caches
/// in-flight Tasks keyed by priceId, exposes a click-handler-friendly
/// `awaitOutcome` that returns instantly when ready or blocks until in-flight
/// completes (per the user's "wait, don't take the default path" preference
/// for in-flight case — see HEL-5326 design discussion).
///
/// Design properties:
///   * `prefetch` returns immediately, never blocks. Tasks run on detached
///     context so MainActor isn't held during network I/O.
///   * Idempotent on the same priceId — re-calling prefetch for a priceId
///     already in the cache is a no-op (avoids duplicating work if the
///     paywall re-renders).
///   * `cancelAll` cancels in-flight URLSession tasks via Swift's Task
///     cancellation propagation (URLSession.data(for:) responds to it) and
///     clears the cache so subsequent `awaitOutcome` calls return
///     `.notStarted`.
///   * MainActor-isolated for simplicity: paywall lifecycle hooks already
///     run on the main thread, click handlers do too. Network calls are
///     dispatched off-actor via `Task.detached`.
@MainActor
final class PaddleCheckoutPrefetchCoordinator {

    /// Singleton used by Stage 5 (ExternalWebCheckoutManager) to look up
    /// cached results from the paywall-display-time prefetch. Tests should
    /// build their own instance via the designated initializer with
    /// MockURLProtocol-backed clients to avoid singleton state leakage
    /// between tests.
    static let shared = PaddleCheckoutPrefetchCoordinator()

    private let banditClient: HeliumPaymentAPIClient
    private let bffClient: PaddleBFFClient

    /// In-flight or completed prefetch Tasks, keyed by priceId. Storing the
    /// Task itself (not just the outcome) lets `awaitOutcome` block until
    /// completion when the click arrives faster than the network — Swift's
    /// `await task.value` returns immediately if already completed.
    private var cache: [String: Task<PaddlePrefetchOutcome, Never>] = [:]

    init(
        banditClient: HeliumPaymentAPIClient = .shared,
        bffClient: PaddleBFFClient = PaddleBFFClient()
    ) {
        self.banditClient = banditClient
        self.bffClient = bffClient
    }

    /// Schedules prefetch tasks for each priceId in parallel. Returns
    /// immediately. Tasks already in the cache for a given priceId are
    /// preserved (no-op for re-entries) so multiple paywall onAppear
    /// passes don't fan-out duplicate requests.
    func prefetch(
        priceIds: [String],
        paddleClientToken: String,
        iosBundleId: String?
    ) {
        for priceId in priceIds {
            if cache[priceId] != nil { continue }

            // Capture references to the clients locally so the detached
            // task can run them off-actor without crossing the MainActor
            // boundary on every URLSession call.
            let bandit = banditClient
            let bff = bffClient

            cache[priceId] = Task.detached(priority: .userInitiated) {
                await Self.runPrefetchChain(
                    priceId: priceId,
                    paddleClientToken: paddleClientToken,
                    iosBundleId: iosBundleId,
                    banditClient: bandit,
                    bffClient: bff
                )
            }
        }
    }

    /// Default upper bound for `awaitOutcome` waits. Generous enough that
    /// most prefetches complete well within it (bandit ~400ms + Paddle BFF
    /// ~700ms = ~1.1s typical), tight enough that a stuck task doesn't
    /// freeze the Subscribe-tap handler indefinitely. Tunable per call for
    /// tests that want a tighter or looser budget.
    static let defaultAwaitTimeoutSeconds: TimeInterval = 3.0

    /// Returns the cached outcome for a priceId. Blocks until the in-flight
    /// task completes OR the timeout elapses, whichever comes first.
    /// Returns `.notStarted` for priceIds that were never prefetched.
    ///
    /// Timeout behavior (Bugbot review): URLSession's default timeout is
    /// 60s, so an unbounded wait could freeze the Subscribe-tap UI for up
    /// to a minute on a stuck request. On timeout we surface `.failed` so
    /// the caller in `ExternalWebCheckoutManager.startCheckoutFlow` falls
    /// through to the safety-net branch (open Safari without ctx; bundle
    /// does its own fetch — current behavior, no regression). The
    /// in-flight Task continues to completion in the background; we just
    /// stop observing it from the click handler's perspective.
    ///
    /// Implementation note: an earlier version used `withTaskGroup`, but
    /// `withTaskGroup` waits for ALL child tasks to complete before
    /// returning — and `await task.value` doesn't respond to cooperative
    /// cancellation (Task.value just waits for the underlying Task, no
    /// matter what). So the group would return only when the cached Task
    /// actually finished, defeating the timeout (Bugbot's second flag on
    /// this method). The fix is `withCheckedContinuation` plus a one-shot
    /// guard — the function returns as soon as either observer Task wins
    /// the race, regardless of what the loser is doing.
    func awaitOutcome(
        priceId: String,
        timeout: TimeInterval = PaddleCheckoutPrefetchCoordinator.defaultAwaitTimeoutSeconds
    ) async -> PaddlePrefetchOutcome {
        guard let task = cache[priceId] else {
            return .notStarted
        }

        let timeoutNanos = UInt64(timeout * 1_000_000_000)

        return await withCheckedContinuation { (continuation: CheckedContinuation<PaddlePrefetchOutcome, Never>) in
            // One-shot resume guard. Whichever observer Task wins the race
            // calls `tryResume()`; the loser's call returns false and is a
            // no-op. Lock-protected so the two observers can't race on the
            // resumed flag.
            let resumeGuard = ResumeGuard()

            // Observer 1: wait for the cached Task to complete.
            // Detached so it doesn't pin MainActor (the coordinator is
            // @MainActor; plain `Task { }` would inherit that isolation
            // and serialize the wait against the click handler).
            Task.detached(priority: .userInitiated) {
                let outcome = await task.value
                if resumeGuard.tryResume() {
                    continuation.resume(returning: outcome)
                }
                // If the timeout already fired, the cached Task continues
                // running in the background — we just don't observe it
                // from this awaitOutcome call. The cache entry stays
                // populated, so subsequent awaitOutcome calls for the
                // same priceId can pick up the eventual result.
            }

            // Observer 2: timeout. Task.sleep responds to cancellation
            // cooperatively (via try?), so a tearDown that cancels in-
            // flight tasks doesn't leak this observer.
            Task.detached(priority: .userInitiated) {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                if resumeGuard.tryResume() {
                    continuation.resume(returning: .failed(
                        error: PaddlePrefetchAwaitTimeout(priceId: priceId, timeout: timeout)
                    ))
                }
            }
        }
    }

    /// Cancels in-flight tasks for the specified priceIds only and removes
    /// them from the cache. Use this when a paywall closes — pass the
    /// closing paywall's priceIds so other still-displayed paywalls keep
    /// their cached outcomes (Bugbot review: previously `cancelAll()` here
    /// would wipe every other paywall's cache too, since the coordinator
    /// is a singleton).
    ///
    /// Cancellation propagates into `URLSession.data(for:)` so the
    /// underlying network requests are torn down too, not just the Swift
    /// Tasks wrapping them. Unknown priceIds are silently ignored — safe
    /// to over-call.
    func cancel(priceIds: [String]) {
        for priceId in priceIds {
            if let task = cache.removeValue(forKey: priceId) {
                task.cancel()
            }
        }
    }

    /// Cancels every in-flight task and clears the cache. Use only when
    /// you genuinely want a global wipe (test tearDown, app backgrounding).
    /// For paywall close, prefer `cancel(priceIds:)` so concurrent
    /// paywalls don't lose their caches.
    ///
    /// This synchronous variant signals cancellation but doesn't wait for
    /// the Tasks to actually stop. Tests that need a hard barrier (e.g.
    /// before resetting MockURLProtocol's static state) should call
    /// `cancelAllAndAwait()` instead.
    func cancelAll() {
        for (_, task) in cache {
            task.cancel()
        }
        cache.removeAll()
    }

    /// Like `cancelAll`, but also awaits each Task's completion. Use when
    /// you need a hard barrier — e.g. test tearDown that's about to mutate
    /// shared state the in-flight Tasks could still touch.
    func cancelAllAndAwait() async {
        let tasks = Array(cache.values)
        cache.removeAll()
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            _ = await task.value
        }
    }

    // MARK: - ctx encoding (Stage 6)

    /// Encodes a `.ready` outcome into a JSON-friendly dict that
    /// `ExternalWebCheckoutManager.buildEnrichedCheckoutURL` merges into
    /// `ctx.paddleBootstrap`. The bundler in Safari reads this and skips
    /// its own bandit + Paddle BFF round-trips entirely.
    ///
    /// Returns nil for `.alreadyEntitled` (Stage 5 short-circuits before
    /// building the URL), `.failed`, and `.notStarted` (those default to
    /// the bundle's existing fetch path with no ctx hint).
    ///
    /// `priceId` is included as an explicit top-level field so the bundler
    /// can validate the bootstrap matches the user's currently-selected
    /// product without digging it out of Paddle's response shape (Bugbot
    /// review on bundler PR #63 flagged that relying on
    /// `paddleCheckoutResponse.data.items[0].price_id` would silently
    /// disable the optimization if Paddle ever renamed that field).
    ///
    /// Shape:
    /// ```
    /// {
    ///     "priceId": "pri_xxx",
    ///     "banditResponse": { "transactionId", "paddleCustomerId"?, "isKnownCustomer", "requestId" },
    ///     "paddleCheckoutResponse": { ... full Paddle BFF response ... }
    /// }
    /// ```
    nonisolated static func encodeBootstrapToCtx(
        _ outcome: PaddlePrefetchOutcome,
        priceId: String
    ) -> [String: Any]? {
        guard case let .ready(bandit, paddle) = outcome else {
            return nil
        }

        var banditDict: [String: Any] = [
            "transactionId": bandit.transactionId,
            "isKnownCustomer": bandit.isKnownCustomer,
            "requestId": bandit.requestId,
        ]
        if let customerId = bandit.paddleCustomerId, !customerId.isEmpty {
            banditDict["paddleCustomerId"] = customerId
        }

        // Paddle's BFF response is rich and only the bundle parses it
        // fully — round-trip the full body so we don't accidentally drop
        // fields. Stage 3's PaddleTransactionCheckoutResult preserves the
        // raw bytes specifically for this purpose.
        let paddleDict = (try? JSONSerialization.jsonObject(with: paddle.rawBody)) as? [String: Any] ?? [:]

        return [
            "priceId": priceId,
            "banditResponse": banditDict,
            "paddleCheckoutResponse": paddleDict,
        ]
    }

    // MARK: - Composite key helpers

    /// "pro_xxx:pri_yyy" → "pri_yyy". Returns nil for malformed input.
    ///
    /// Strict shape: exactly one `:` separator with non-empty halves and a
    /// `pri_`-prefixed suffix. Rejects:
    ///   * "pri_just_a_priceid"   (no colon — not a composite)
    ///   * "pro_x:extra:pri_y"    (too many colons — ambiguous)
    ///   * ":pri_orphan"          (missing productId half)
    ///   * "pro_x:something_else" (suffix doesn't look like a priceId)
    ///
    /// Single source of truth for parsing
    /// `HeliumPaywallInfo.webProductsOfferedPaddle` composite keys — the
    /// click-time path in ExternalWebCheckoutManager calls this for one
    /// productKey, `extractPriceIds(from:)` calls it for the whole array
    /// on paywall display.
    nonisolated static func extractPriceId(from compositeKey: String) -> String? {
        let parts = compositeKey.split(
            separator: ":",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[1].hasPrefix("pri_") else {
            return nil
        }
        return parts[1]
    }

    /// Bulk variant for paywall-display-time fan-out. Filters out
    /// malformed entries silently — a single bad row in the on-launch
    /// payload shouldn't kill the prefetch chain.
    nonisolated static func extractPriceIds(from composites: [String]) -> [String] {
        return composites.compactMap(extractPriceId)
    }

    // MARK: - Internal chain runner

    /// Bandit → BFF, with the alreadyEntitled short-circuit. Pure function
    /// (no MainActor / shared-state dependency) so it can run off-actor in
    /// the detached task.
    ///
    /// `nonisolated` is load-bearing: without it, this static method
    /// inherits the enclosing class's `@MainActor` isolation. The
    /// `Task.detached` at the call site would then immediately hop back
    /// to MainActor to invoke this — defeating the whole point of
    /// dispatching network orchestration off the main thread (Bugbot
    /// flagged this on the initial review). With `nonisolated`, the
    /// detached task body runs on the global concurrent executor as
    /// intended, and parallel prefetches don't compete for MainActor
    /// time between network suspension points.
    private nonisolated static func runPrefetchChain(
        priceId: String,
        paddleClientToken: String,
        iosBundleId: String?,
        banditClient: HeliumPaymentAPIClient,
        bffClient: PaddleBFFClient
    ) async -> PaddlePrefetchOutcome {
        // Step 1: bandit. If this throws alreadyEntitled, BFF is skipped
        // entirely (no checkout session needed for a customer who already
        // owns the product).
        let banditResponse: PaddleCreateTransactionForPaywallResponse
        do {
            banditResponse = try await banditClient.createPaddleTransactionForPaywall(priceId: priceId)
        } catch let PaddlePrefetchError.alreadyEntitled(code, message) {
            return .alreadyEntitled(code: code, message: message)
        } catch {
            return .failed(error: error)
        }

        // Step 2: Paddle BFF. Uses transaction_id from step 1.
        do {
            let paddleResult = try await bffClient.createTransactionCheckout(
                transactionId: banditResponse.transactionId,
                paddleClientToken: paddleClientToken,
                iosBundleId: iosBundleId
            )
            return .ready(bandit: banditResponse, paddle: paddleResult)
        } catch {
            return .failed(error: error)
        }
    }
}
