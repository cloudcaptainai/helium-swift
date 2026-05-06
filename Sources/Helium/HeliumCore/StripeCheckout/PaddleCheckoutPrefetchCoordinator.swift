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
///     Same fallback as `.failed`.
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
/// completes (per the user's "wait, don't fall back" preference for in-flight
/// case — see HEL-5326 design discussion).
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

    /// Returns the cached outcome for a priceId. Blocks until the in-flight
    /// task completes (per the design: never fall back to the slow path
    /// when a prefetch is in-flight; just wait for it). Returns
    /// `.notStarted` for priceIds that were never prefetched.
    func awaitOutcome(priceId: String) async -> PaddlePrefetchOutcome {
        guard let task = cache[priceId] else {
            return .notStarted
        }
        return await task.value
    }

    /// Cancels every in-flight task and clears the cache. Called when the
    /// paywall is dismissed without a click — we don't want stale Tasks
    /// running after the user has left.
    ///
    /// Cancellation propagates into `URLSession.data(for:)` so the
    /// underlying network requests are torn down too, not just the Swift
    /// Tasks wrapping them.
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
    /// building the URL), `.failed`, and `.notStarted` (those fall back to
    /// the bundle's existing fetch path with no ctx hint).
    ///
    /// Shape:
    /// ```
    /// {
    ///     "banditResponse": { "transactionId", "paddleCustomerId"?, "isKnownCustomer", "requestId" },
    ///     "paddleCheckoutResponse": { ... full Paddle BFF response ... }
    /// }
    /// ```
    nonisolated static func encodeBootstrapToCtx(_ outcome: PaddlePrefetchOutcome) -> [String: Any]? {
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
            "banditResponse": banditDict,
            "paddleCheckoutResponse": paddleDict,
        ]
    }

    // MARK: - Composite key helpers

    /// Extracts the priceId portion from "pro_xxx:pri_yyy" composite keys
    /// returned in `HeliumPaywallInfo.webProductsOfferedPaddle`. Filters
    /// out malformed entries (no colon, suffix doesn't start with `pri_`)
    /// so a single bad row in the on-launch payload doesn't kill the
    /// prefetch chain — bandit will reject any priceId we send that
    /// doesn't actually exist anyway.
    nonisolated static func extractPriceIds(from composites: [String]) -> [String] {
        return composites.compactMap { key in
            guard let suffix = key.split(separator: ":").last.map(String.init),
                  suffix.hasPrefix("pri_") else {
                return nil
            }
            return suffix
        }
    }

    // MARK: - Internal chain runner

    /// Bandit → BFF, with the alreadyEntitled short-circuit. Pure function
    /// (no MainActor / shared-state dependency) so it can run off-actor in
    /// the detached task.
    private static func runPrefetchChain(
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
