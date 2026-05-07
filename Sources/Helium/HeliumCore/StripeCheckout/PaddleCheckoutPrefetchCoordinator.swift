import Foundation

/// One-shot resume guard for `withCheckedContinuation` races: the first
/// observer to call `tryResume` wins, the rest are no-ops. Lock-protected
/// because the observers run on different Tasks.
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

/// Surfaced as the `Error` of a `.failed` outcome when `awaitOutcome`
/// exceeds its timeout budget.
struct PaddlePrefetchAwaitTimeout: LocalizedError {
    let priceId: String
    let timeout: TimeInterval

    var errorDescription: String? {
        return "Paddle prefetch await timed out after \(timeout)s for priceId \(priceId)"
    }
}

/// Outcomes the prefetch coordinator can produce for a given priceId.
/// Pattern-matched at click-time to decide what the Subscribe-tap handler
/// does:
///
///   * `.ready` — embed both responses in `ctx.paddleBootstrap` and open Safari
///   * `.alreadyEntitled` — skip Safari entirely, fire `purchase_already_entitled`,
///     resolve as `.preCheckResolved`
///   * `.failed` — open Safari WITHOUT `ctx.paddleBootstrap`; the bundle
///     does its own fetch (no regression from current behavior)
///   * `.notStarted` — no prefetch was scheduled for this priceId. Same
///     treatment as `.failed`.
enum PaddlePrefetchOutcome {
    case ready(
        bandit: PaddleCreateTransactionForPaywallResponse,
        paddle: PaddleTransactionCheckoutResult
    )
    /// Bandit returned 409 `duplicate_subscription` for this priceId.
    /// `existingSubscriptionId` carries the buyer's existing Paddle
    /// subscription id (for the bundle's `canonicalJoinTransactionId`
    /// analytics field) when the 409 body surfaced one — nil otherwise.
    case alreadyEntitled(code: String, message: String, existingSubscriptionId: String?)
    case failed(error: Error)
    case notStarted
}

/// Runs bandit + Paddle BFF in parallel per priceId at paywall-display
/// time, caches the in-flight Tasks, and exposes a click-handler-friendly
/// `awaitOutcome` that returns instantly when the result is ready or
/// blocks (with a timeout) until it is.
///
/// Cache ownership is per-paywall-session: the cache key is
/// `(sessionId, priceId)`. Two paywalls displayed concurrently with the
/// same priceId get independent entries, so closing one doesn't wipe the
/// other's cached outcome.
///
/// MainActor-isolated because the integration points (paywall lifecycle
/// events, click-handler) are main-thread; URLSession orchestration is
/// dispatched off-actor via `Task.detached` so network I/O doesn't pin
/// the main thread.
@MainActor
final class PaddleCheckoutPrefetchCoordinator {

    static let shared = PaddleCheckoutPrefetchCoordinator()

    private let banditClient: HeliumPaymentAPIClient
    private let bffClient: PaddleBFFClient

    /// Cache keyed by `(sessionId, priceId)` composite. Storing the Task
    /// itself (not just the eventual outcome) lets `awaitOutcome` block on
    /// a still-in-flight result; `await task.value` returns immediately if
    /// the task has already completed.
    private var cache: [CacheKey: Task<PaddlePrefetchOutcome, Never>] = [:]

    private struct CacheKey: Hashable {
        let sessionId: String
        let priceId: String
    }

    init(
        banditClient: HeliumPaymentAPIClient = .shared,
        bffClient: PaddleBFFClient = PaddleBFFClient()
    ) {
        self.banditClient = banditClient
        self.bffClient = bffClient
    }

    // MARK: - One-liner entry points for paywall lifecycle events

    /// Fire when a paywall becomes visible. Reads the trigger's
    /// `webProductsOfferedPaddle` and the org's paddle client token from
    /// the SDK's existing config, extracts priceIds, and schedules a
    /// prefetch per priceId. No-op when any prerequisite is missing — the
    /// click handler's safety-net path covers that.
    func handlePaywallOpen(paywallSession: PaywallSession) {
        guard let info = paywallSession.paywallInfoWithBackups,
              let webProducts = info.webProductsOfferedPaddle,
              !webProducts.isEmpty,
              let clientToken = HeliumFetchedConfigManager.shared.fetchedConfig?.paddleClientToken,
              !clientToken.isEmpty else {
            return
        }
        let priceIds = Self.extractPriceIds(from: webProducts)
        guard !priceIds.isEmpty else { return }

        prefetch(
            sessionId: paywallSession.sessionId,
            priceIds: priceIds,
            paddleClientToken: clientToken,
            iosBundleId: Bundle.main.bundleIdentifier
        )
    }

    /// Fire when a paywall closes. Cancels in-flight prefetches owned by
    /// this paywall session only — other still-displayed paywalls keep
    /// their caches.
    func handlePaywallClose(paywallSession: PaywallSession) {
        cancelForSession(sessionId: paywallSession.sessionId)
    }

    // MARK: - Primitives (also called directly by tests)

    /// Schedules prefetch tasks for each priceId in parallel under the
    /// given session's ownership. Returns immediately. Re-calling for the
    /// same `(sessionId, priceId)` is a no-op so re-renders don't
    /// fan-out duplicate requests.
    func prefetch(
        sessionId: String,
        priceIds: [String],
        paddleClientToken: String,
        iosBundleId: String?
    ) {
        for priceId in priceIds {
            let key = CacheKey(sessionId: sessionId, priceId: priceId)
            if cache[key] != nil { continue }

            // Capture clients locally so the detached task runs them
            // off-actor without crossing the MainActor boundary on every
            // URLSession call.
            let bandit = banditClient
            let bff = bffClient

            cache[key] = Task.detached(priority: .userInitiated) {
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
    /// most prefetches complete well within it (bandit ~400ms + Paddle
    /// BFF ~700ms ≈ 1.1s typical), tight enough that a stuck task doesn't
    /// freeze the Subscribe-tap handler indefinitely.
    static let defaultAwaitTimeoutSeconds: TimeInterval = 3.0

    /// Returns the cached outcome for `(sessionId, priceId)`. Blocks until
    /// the in-flight task completes OR the timeout elapses, whichever
    /// comes first. Returns `.notStarted` for entries that were never
    /// prefetched. On timeout, returns `.failed` so the caller's
    /// safety-net branch fires.
    ///
    /// We use `withCheckedContinuation` rather than `withTaskGroup`
    /// because the group implicitly waits for ALL its child tasks before
    /// returning, and `await task.value` doesn't respond to cooperative
    /// cancellation — so a buggy implementation built on TaskGroup would
    /// effectively block until the underlying URLSession completes.
    /// Continuations let us return the moment whichever observer wins.
    func awaitOutcome(
        sessionId: String,
        priceId: String,
        timeout: TimeInterval = PaddleCheckoutPrefetchCoordinator.defaultAwaitTimeoutSeconds
    ) async -> PaddlePrefetchOutcome {
        let key = CacheKey(sessionId: sessionId, priceId: priceId)
        guard let task = cache[key] else {
            return .notStarted
        }

        let timeoutNanos = UInt64(timeout * 1_000_000_000)

        return await withCheckedContinuation { (continuation: CheckedContinuation<PaddlePrefetchOutcome, Never>) in
            let resumeGuard = ResumeGuard()

            // Observer 1: wait for the cached Task. Detached so it doesn't
            // pin MainActor.
            Task.detached(priority: .userInitiated) {
                let outcome = await task.value
                if resumeGuard.tryResume() {
                    continuation.resume(returning: outcome)
                }
            }

            // Observer 2: timeout. Task.sleep is cancellation-cooperative,
            // so a tearDown that cancels in-flight tasks won't leak this
            // observer.
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

    /// Click-handler gather step: awaits prefetch outcomes for ALL
    /// priceIds on the paywall in parallel before the SDK opens Safari.
    ///
    /// **All-or-bounded by design.** The bundle is the user-facing
    /// surface in Safari; if it opens with missing bootstraps, the
    /// user can switch products and trigger live-fetch loaders inside
    /// Safari — the very UX the prefetch optimization exists to
    /// eliminate. Holding the in-app click for a moment to ensure
    /// every bootstrap is in `ctx.paddleBootstraps` before redirect
    /// is the explicit trade: brief in-app wait beats Safari loaders.
    ///
    /// `withTaskGroup` runs all priceIds concurrently — wall-clock is
    /// bounded by max(per-priceId timeout, slowest priceId). Each
    /// `awaitOutcome` has the default 3s timeout, so a stuck priceId
    /// caps the worst-case click latency at 3s (resolves to `.failed`
    /// which the encoders skip).
    func collectPrefetchOutcomes(
        sessionId: String,
        priceIds: [String]
    ) async -> [String: PaddlePrefetchOutcome] {
        guard !priceIds.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, PaddlePrefetchOutcome).self) { group in
            for priceId in priceIds {
                group.addTask { @MainActor in
                    let outcome = await self.awaitOutcome(
                        sessionId: sessionId, priceId: priceId
                    )
                    return (priceId, outcome)
                }
            }
            var result: [String: PaddlePrefetchOutcome] = [:]
            for await (priceId, outcome) in group {
                result[priceId] = outcome
            }
            return result
        }
    }

    /// Cancels every in-flight task owned by this session and removes its
    /// cache entries. Other sessions are untouched. Cancellation
    /// propagates into URLSession.data(for:) so the underlying network
    /// requests are torn down too.
    func cancelForSession(sessionId: String) {
        for key in Array(cache.keys) where key.sessionId == sessionId {
            if let task = cache.removeValue(forKey: key) {
                task.cancel()
            }
        }
    }

    /// Cancels every in-flight task across all sessions. Use only when
    /// you genuinely want a global wipe (test tearDown, app
    /// backgrounding). For paywall close prefer `handlePaywallClose` /
    /// `cancelForSession`.
    ///
    /// Synchronous variant: signals cancellation but doesn't wait for
    /// Tasks to actually stop. Tests that need a hard barrier (e.g.
    /// before resetting MockURLProtocol's static state) should call
    /// `cancelAllAndAwait()`.
    func cancelAll() {
        for (_, task) in cache {
            task.cancel()
        }
        cache.removeAll()
    }

    /// Like `cancelAll`, but also awaits each Task's completion. Use when
    /// you need a hard barrier before mutating shared state in-flight
    /// Tasks could touch.
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

    // MARK: - ctx encoding

    /// Encodes ready-outcome bootstraps into the map the bundler reads from
    /// `ctx.paddleBootstraps`, keyed by priceId.
    ///
    /// **Why a map, not a single bootstrap:** the bundle in Safari can
    /// switch products mid-flow (user lands on it after tapping product A
    /// in iOS, then picks product B in the web paywall). The bundle calls
    /// `ensurePaddleInitForProduct(product)` each time the selected product
    /// changes; that lookup needs a bootstrap for whichever priceId is
    /// currently selected, not just the iOS-tapped one.
    ///
    /// **Why we trim the Paddle BFF response:** the raw response is ~6KB
    /// and includes large blocks the bundle never reads (`experimentation`,
    /// `settings`, `custom_data`, non-Apple-Pay payment methods). Sending
    /// it whole for N products would blow Safari's URL budget. The trimmed
    /// shape mirrors `PaddleBFFCheckoutData` in
    /// `bundler-service/server/heliumStandalonePaddle.ts` — when the bundle
    /// adds new field reads, both sides update together.
    ///
    /// Returns nil when no outcome is `.ready` so the caller can omit the
    /// `paddleBootstraps` field entirely from the ctx.
    ///
    /// Shape:
    /// ```
    /// {
    ///     "pri_xxx": {
    ///         "banditResponse":         { "transactionId", "paddleCustomerId"?, "isKnownCustomer", "requestId" },
    ///         "paddleCheckoutResponse": { "data": { id, transaction_id, status, currency_code, ... trimmed ... } }
    ///     },
    ///     "pri_yyy": { ... }
    /// }
    /// ```
    nonisolated static func encodeBootstrapsToCtx(
        outcomesByPriceId: [String: PaddlePrefetchOutcome]
    ) -> [String: Any]? {
        return encodeFilteredOutcomes(outcomesByPriceId: outcomesByPriceId) { outcome in
            guard case let .ready(bandit, paddle) = outcome else { return nil }
            return encodeReadyBootstrap(bandit: bandit, paddle: paddle)
        }
    }

    /// Encodes `.alreadyEntitled` outcomes into the map the bundler reads
    /// from `ctx.paddleAlreadyEntitled`, keyed by priceId. The bundle uses
    /// this to short-circuit straight to its `kind: 'alreadyEntitled'`
    /// branch when the user clicks an entitled-but-not-tapped product in
    /// Safari — without this map, the bundle would have to call bandit
    /// itself just to discover the 409, defeating the whole point of
    /// pre-fetching (loader on screen + extra round-trip).
    ///
    /// Returns nil when no outcome is `.alreadyEntitled` so the caller
    /// can omit the field entirely from the ctx.
    ///
    /// Shape:
    /// ```
    /// {
    ///     "pri_yearly":   { "code": "duplicate_subscription", "message": "..." },
    ///     "pri_lifetime": { "code": "duplicate_subscription", "message": "..." }
    /// }
    /// ```
    nonisolated static func encodeAlreadyEntitledToCtx(
        outcomesByPriceId: [String: PaddlePrefetchOutcome]
    ) -> [String: Any]? {
        return encodeFilteredOutcomes(outcomesByPriceId: outcomesByPriceId) { outcome in
            guard case let .alreadyEntitled(code, message, existingSubscriptionId) = outcome else { return nil }
            var entry: [String: Any] = ["code": code, "message": message]
            if let subId = existingSubscriptionId, !subId.isEmpty {
                entry["existingSubscriptionId"] = subId
            }
            return entry
        }
    }

    /// Generic priceId-keyed encoder: applies `transform` to each
    /// outcome, accumulates non-nil results into a map keyed by priceId,
    /// returns nil when nothing matched (so the caller can omit the
    /// field entirely from the ctx instead of shipping an empty `{}`).
    /// Shared between `encodeBootstrapsToCtx` (filters `.ready`) and
    /// `encodeAlreadyEntitledToCtx` (filters `.alreadyEntitled`).
    private nonisolated static func encodeFilteredOutcomes(
        outcomesByPriceId: [String: PaddlePrefetchOutcome],
        transform: (PaddlePrefetchOutcome) -> [String: Any]?
    ) -> [String: Any]? {
        var result: [String: Any] = [:]
        for (priceId, outcome) in outcomesByPriceId {
            if let entry = transform(outcome) {
                result[priceId] = entry
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Builds one `(banditResponse, paddleCheckoutResponse)` bootstrap for
    /// a single ready outcome. Caller (`encodeBootstrapsToCtx`) places it
    /// under the priceId key.
    private nonisolated static func encodeReadyBootstrap(
        bandit: PaddleCreateTransactionForPaywallResponse,
        paddle: PaddleTransactionCheckoutResult
    ) -> [String: Any] {
        var banditDict: [String: Any] = [
            "transactionId": bandit.transactionId,
            "isKnownCustomer": bandit.isKnownCustomer,
            "requestId": bandit.requestId,
        ]
        if let customerId = bandit.paddleCustomerId, !customerId.isEmpty {
            banditDict["paddleCustomerId"] = customerId
        }

        let trimmedPaddleResponse = trimPaddleCheckoutResponse(rawBody: paddle.rawBody)

        return [
            "banditResponse": banditDict,
            "paddleCheckoutResponse": trimmedPaddleResponse,
        ]
    }

    /// Allow-list trim of the Paddle BFF `/transaction-checkout` response.
    /// Keeps only the fields the bundle's `runPaddleApplePayInit` reads
    /// (see `PaddleBFFCheckoutData` in heliumStandalonePaddle.ts). Drops
    /// everything else — `experimentation` (~2KB), `settings` (~1KB),
    /// `custom_data`, non-Apple-Pay payment methods, per-item totals/quantities,
    /// `created_at`, etc.
    ///
    /// Defensive: if the body is unparseable we return `{ "data": [:] }`
    /// rather than throwing. The bundle's null-checks on required fields
    /// (`id`, `transaction_id`) will then make it default to its
    /// live-fetch path, the same way it would for a never-prefetched
    /// product.
    private nonisolated static func trimPaddleCheckoutResponse(rawBody: Data) -> [String: Any] {
        guard let parsed = (try? JSONSerialization.jsonObject(with: rawBody)) as? [String: Any],
              let rawData = parsed["data"] as? [String: Any] else {
            return ["data": [String: Any]()]
        }
        return ["data": trimPaddleCheckoutData(rawData)]
    }

    /// Pure helper that copies only allow-listed fields from the raw
    /// Paddle BFF `data` dict into a new dict. Mirrors the
    /// `PaddleBFFCheckoutData` interface in heliumStandalonePaddle.ts.
    private nonisolated static func trimPaddleCheckoutData(_ raw: [String: Any]) -> [String: Any] {
        var trimmed: [String: Any] = [:]

        // Top-level scalars the bundle reads on the BFF response.
        for key in [
            "id", "transaction_id", "status", "currency_code",
            "ip_geo_country_code", "ip_geo_postal_code",
        ] {
            if let value = raw[key] { trimmed[key] = value }
        }

        // customer.email (read for prefilledEmail). Keep `id` for parity
        // with the typed interface even though only `.email` is read today.
        if let customer = raw["customer"] as? [String: Any] {
            var c: [String: Any] = [:]
            if let id = customer["id"] { c["id"] = id }
            if let email = customer["email"] { c["email"] = email }
            if !c.isEmpty { trimmed["customer"] = c }
        }

        // seller.name → Apple Pay billingAgreement disclosure.
        if let seller = raw["seller"] as? [String: Any], let name = seller["name"] {
            trimmed["seller"] = ["name": name]
        }

        // items[]: only billing_cycle / trial_period / price.unit_price.
        if let rawItems = raw["items"] as? [[String: Any]] {
            trimmed["items"] = rawItems.map(trimPaddleItem)
        }

        // recurring_totals.total / totals.total — only `.total` is read.
        for key in ["recurring_totals", "totals"] {
            if let dict = raw[key] as? [String: Any], let total = dict["total"] {
                trimmed[key] = ["total": total]
            }
        }

        // discount: passed through fully — all of {id, type, amount,
        // recur, maximum_recurring_intervals} are read by the bundle's
        // multi-phase Apple Pay representation.
        if let discount = raw["discount"] {
            trimmed["discount"] = discount
        }

        // payments.methods_available filtered to PI_APPLE_PAY only, with
        // each entry trimmed to {type, stripe_options}.
        if let payments = raw["payments"] as? [String: Any],
           let methods = payments["methods_available"] as? [[String: Any]] {
            let applePayMethods = methods.compactMap(trimApplePayMethod)
            if !applePayMethods.isEmpty {
                trimmed["payments"] = ["methods_available": applePayMethods]
            }
        }

        return trimmed
    }

    private nonisolated static func trimPaddleItem(_ item: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        if let billing = item["billing_cycle"] { out["billing_cycle"] = billing }
        if let trial = item["trial_period"] { out["trial_period"] = trial }
        if let price = item["price"] as? [String: Any], let unit = price["unit_price"] {
            out["price"] = ["unit_price": unit]
        }
        return out
    }

    private nonisolated static func trimApplePayMethod(_ method: [String: Any]) -> [String: Any]? {
        guard let type = method["type"] as? String, type == "PI_APPLE_PAY" else { return nil }
        var out: [String: Any] = ["type": type]
        if let stripeOpts = method["stripe_options"] as? [String: Any] {
            // Only the two fields the bundle reads: api_key, country_code.
            var trimmedStripe: [String: Any] = [:]
            for key in ["api_key", "country_code"] {
                if let v = stripeOpts[key] { trimmedStripe[key] = v }
            }
            if !trimmedStripe.isEmpty { out["stripe_options"] = trimmedStripe }
        }
        return out
    }

    // MARK: - Tapped-product short-circuit decision

    /// Decides whether the tapped product warrants short-circuiting the
    /// click flow (skip Safari, treat as restored). Returns the
    /// `(code, message)` when the *tapped* priceId is alreadyEntitled
    /// WITH a restorable code (currently only `duplicate_subscription`);
    /// nil otherwise.
    ///
    /// **Crucially, OTHER priceIds being alreadyEntitled don't trigger
    /// short-circuit.** Real scenario: paywall offers monthly + yearly,
    /// user already owns yearly, user taps monthly. `outcomes["pri_yearly"]`
    /// will be `.alreadyEntitled` and `outcomes["pri_monthly"]` will be
    /// `.ready` — we want to allow the monthly purchase to proceed
    /// normally, not block it because of the unrelated yearly entitlement.
    ///
    /// **And: only `duplicate_subscription` short-circuits to restored.**
    /// Other alreadyEntitled-class codes (e.g. `trial_already_used`)
    /// represent a failure UX in the bundle — entitled_failure with a
    /// redirect to paymentFailureUrl. The SDK opens the bundle for those
    /// codes and lets the bundle's existing routing handle it. This
    /// mirrors `routePaddle409` in the bundler.
    nonisolated static func tappedShortCircuit(
        in outcomes: [String: PaddlePrefetchOutcome],
        tappedPriceId: String
    ) -> (code: String, message: String)? {
        if case let .alreadyEntitled(code, message, _) = outcomes[tappedPriceId] ?? .notStarted,
           PaddleErrorCodes.isRestorable(code) {
            return (code, message)
        }
        return nil
    }

    // MARK: - Composite key helpers

    /// "pro_xxx:pri_yyy" → "pri_yyy". Returns nil for malformed input.
    /// Strict shape: exactly one ":" separator with non-empty halves and
    /// a `pri_`-prefixed suffix.
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

    /// Bulk variant. Filters malformed entries silently — a single bad
    /// row in the on-launch payload shouldn't kill the prefetch chain.
    nonisolated static func extractPriceIds(from composites: [String]) -> [String] {
        return composites.compactMap(extractPriceId)
    }

    // MARK: - Internal chain runner

    /// Bandit → BFF, with the alreadyEntitled short-circuit. Pure
    /// function (no MainActor / shared-state dependency) so it runs
    /// off-actor in the detached task.
    ///
    /// `nonisolated` is load-bearing: without it, this static method
    /// inherits the enclosing class's `@MainActor` isolation, and the
    /// `Task.detached` at the call site would hop back to MainActor to
    /// invoke it — defeating the point of off-actor dispatch.
    private nonisolated static func runPrefetchChain(
        priceId: String,
        paddleClientToken: String,
        iosBundleId: String?,
        banditClient: HeliumPaymentAPIClient,
        bffClient: PaddleBFFClient
    ) async -> PaddlePrefetchOutcome {
        // Step 1: bandit. If 409 alreadyEntitled, BFF is skipped — no
        // checkout session needed for a customer who already owns the
        // product.
        let banditResponse: PaddleCreateTransactionForPaywallResponse
        do {
            banditResponse = try await banditClient.createPaddleTransactionForPaywall(priceId: priceId)
        } catch let PaddlePrefetchError.alreadyEntitled(code, message, existingSubscriptionId) {
            return .alreadyEntitled(code: code, message: message, existingSubscriptionId: existingSubscriptionId)
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
