import Foundation

/// One-shot resume guard for `withCheckedContinuation` races.
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

struct PaddlePrefetchAwaitTimeout: LocalizedError {
    let priceId: String
    let timeout: TimeInterval

    var errorDescription: String? {
        return "Paddle prefetch await timed out after \(timeout)s for priceId \(priceId)"
    }
}

struct PaddleCaliforniaBlocked: LocalizedError {
    let postalCode: String

    var errorDescription: String? {
        return "Paddle prefetch blocked for California IP (postal \(postalCode))"
    }
}

enum PaddlePrefetchOutcome {
    case ready(
        bandit: PaddleCreateTransactionForPaywallResponse,
        paddle: PaddleTransactionCheckoutResult
    )
    case alreadyEntitled(code: String, message: String, existingSubscriptionId: String?)
    case failed(error: Error)
    case notStarted
}

@MainActor
final class PaddleCheckoutPrefetchCoordinator {

    static let shared = PaddleCheckoutPrefetchCoordinator()

    private let banditClient: HeliumPaymentAPIClient
    private let bffClient: PaddleBFFClient

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

    // MARK: - Paywall lifecycle hooks

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
            paywallSession: paywallSession,
            priceIds: priceIds,
            paddleClientToken: clientToken,
            iosBundleId: Bundle.main.bundleIdentifier
        )
    }

    func handlePaywallClose(paywallSession: PaywallSession) {
        cancelForSession(sessionId: paywallSession.sessionId)
    }

    // MARK: - Primitives

    /// Re-calling for the same `(sessionId, priceId)` is a no-op.
    func prefetch(
        paywallSession: PaywallSession,
        priceIds: [String],
        paddleClientToken: String,
        iosBundleId: String?
    ) {
        let sessionId = paywallSession.sessionId
        let scope = paywallSession.observabilityScope
        var startedPriceIds: [String] = []
        for priceId in priceIds {
            let key = CacheKey(sessionId: sessionId, priceId: priceId)
            if cache[key] != nil { continue }

            let bandit = banditClient
            let bff = bffClient

            cache[key] = Task.detached(priority: .userInitiated) {
                await Self.runPrefetchChain(
                    priceId: priceId,
                    paddleClientToken: paddleClientToken,
                    iosBundleId: iosBundleId,
                    banditClient: bandit,
                    bffClient: bff,
                    scope: scope
                )
            }
            startedPriceIds.append(priceId)
        }
        if !startedPriceIds.isEmpty {
            HeliumObservabilityManager.shared.track(
                PaddlePrefetchStarted(priceIds: startedPriceIds),
                scope: scope
            )
        }
    }

    static let defaultAwaitTimeoutSeconds: TimeInterval = 3.0

    /// Returns `.notStarted` if no prefetch was scheduled; `.failed` with
    /// `PaddlePrefetchAwaitTimeout` on timeout.
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

        // Continuation, not withTaskGroup: the group waits for ALL children
        // before returning, and `await task.value` ignores cancellation.
        return await withCheckedContinuation { (continuation: CheckedContinuation<PaddlePrefetchOutcome, Never>) in
            let resumeGuard = ResumeGuard()

            Task.detached(priority: .userInitiated) {
                let outcome = await task.value
                if resumeGuard.tryResume() {
                    continuation.resume(returning: outcome)
                }
            }

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

    func cancelForSession(sessionId: String) {
        for key in Array(cache.keys) where key.sessionId == sessionId {
            if let task = cache.removeValue(forKey: key) {
                task.cancel()
            }
        }
    }

    func cancelAll() {
        for (_, task) in cache {
            task.cancel()
        }
        cache.removeAll()
    }

    /// Like `cancelAll`, but waits for each Task to finish. Use as a hard
    /// barrier before mutating shared state in-flight Tasks could touch.
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

    /// Returns nil when no outcome is `.ready` so callers can omit the
    /// field entirely.
    nonisolated static func encodeBootstrapsToCtx(
        outcomesByPriceId: [String: PaddlePrefetchOutcome]
    ) -> [String: Any]? {
        return encodeFilteredOutcomes(outcomesByPriceId: outcomesByPriceId) { outcome in
            guard case let .ready(bandit, paddle) = outcome else { return nil }
            return encodeReadyBootstrap(bandit: bandit, paddle: paddle)
        }
    }

    /// Returns nil when no outcome is `.alreadyEntitled` so callers can
    /// omit the field entirely.
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

    /// Allow-list trim of the Paddle BFF response. On parse failure
    /// returns `{ "data": [:] }` rather than throwing — the bundle's
    /// null-checks then default to its live-fetch path.
    private nonisolated static func trimPaddleCheckoutResponse(rawBody: Data) -> [String: Any] {
        guard let parsed = (try? JSONSerialization.jsonObject(with: rawBody)) as? [String: Any],
              let rawData = parsed["data"] as? [String: Any] else {
            return ["data": [String: Any]()]
        }
        return ["data": trimPaddleCheckoutData(rawData)]
    }

    private nonisolated static func trimPaddleCheckoutData(_ raw: [String: Any]) -> [String: Any] {
        var trimmed: [String: Any] = [:]

        for key in [
            "id", "transaction_id", "status", "currency_code",
            "ip_geo_country_code", "ip_geo_postal_code",
            "created_at",
        ] {
            if let value = raw[key] { trimmed[key] = value }
        }

        if let customer = raw["customer"] as? [String: Any] {
            var c: [String: Any] = [:]
            if let id = customer["id"] { c["id"] = id }
            if let email = customer["email"] { c["email"] = email }
            if !c.isEmpty { trimmed["customer"] = c }
        }

        if let seller = raw["seller"] as? [String: Any], let name = seller["name"] {
            trimmed["seller"] = ["name": name]
        }

        if let rawItems = raw["items"] as? [[String: Any]] {
            trimmed["items"] = rawItems.map(trimPaddleItem)
        }

        for key in ["recurring_totals", "totals"] {
            if let dict = raw[key] as? [String: Any], let total = dict["total"] {
                trimmed[key] = ["total": total]
            }
        }

        if let discount = raw["discount"] {
            trimmed["discount"] = discount
        }

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
            var trimmedStripe: [String: Any] = [:]
            for key in ["api_key", "country_code"] {
                if let v = stripeOpts[key] { trimmedStripe[key] = v }
            }
            if !trimmedStripe.isEmpty { out["stripe_options"] = trimmedStripe }
        }
        return out
    }

    // MARK: - Tapped-product short-circuit decision

    /// Returns `(code, message)` only when the *tapped* priceId is
    /// alreadyEntitled with a restorable code. Other priceIds being
    /// entitled, or non-restorable codes, return nil.
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

    nonisolated static func anyCaliforniaBlocked(
        in outcomes: [String: PaddlePrefetchOutcome]
    ) -> Bool {
        return outcomes.values.contains { outcome in
            if case let .failed(error) = outcome, error is PaddleCaliforniaBlocked {
                return true
            }
            return false
        }
    }

    // MARK: - Composite key helpers

    /// "pro_xxx:pri_yyy" → "pri_yyy". Returns nil for malformed input.
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

    nonisolated static func extractPriceIds(from composites: [String]) -> [String] {
        return composites.compactMap(extractPriceId)
    }

    // MARK: - Internal chain runner

    /// `nonisolated` is load-bearing: without it, this static method
    /// inherits MainActor isolation and `Task.detached` hops back to
    /// the main actor, defeating off-actor URLSession dispatch.
    private nonisolated static func runPrefetchChain(
        priceId: String,
        paddleClientToken: String,
        iosBundleId: String?,
        banditClient: HeliumPaymentAPIClient,
        bffClient: PaddleBFFClient,
        scope: PaywallObservabilityScope
    ) async -> PaddlePrefetchOutcome {
        let chainStart = Date()
        let banditStart = Date()
        let banditResponse: PaddleCreateTransactionForPaywallResponse
        do {
            banditResponse = try await banditClient.createPaddleTransactionForPaywall(priceId: priceId)
            trackBanditCompletion(priceId: priceId, scope: scope, startedAt: banditStart, chainStartedAt: chainStart, result: .success)
        } catch let PaddlePrefetchError.alreadyEntitled(code, message, existingSubscriptionId) {
            trackBanditCompletion(priceId: priceId, scope: scope, startedAt: banditStart, chainStartedAt: chainStart, result: .alreadyEntitled(code: code, message: message))
            return .alreadyEntitled(code: code, message: message, existingSubscriptionId: existingSubscriptionId)
        } catch {
            trackBanditCompletion(priceId: priceId, scope: scope, startedAt: banditStart, chainStartedAt: chainStart, result: .failed(error))
            return .failed(error: error)
        }

        let bffStart = Date()
        do {
            let paddleResult = try await bffClient.createTransactionCheckout(
                transactionId: banditResponse.transactionId,
                paddleClientToken: paddleClientToken,
                iosBundleId: iosBundleId
            )
            if let caPostal = californiaPostalCode(in: paddleResult.rawBody) {
                trackBffCompletion(priceId: priceId, transactionId: banditResponse.transactionId, scope: scope, startedAt: bffStart, chainStartedAt: chainStart, result: .caBlocked(rawBody: paddleResult.rawBody))
                return .failed(error: PaddleCaliforniaBlocked(postalCode: caPostal))
            }
            trackBffCompletion(priceId: priceId, transactionId: banditResponse.transactionId, scope: scope, startedAt: bffStart, chainStartedAt: chainStart, result: .success(rawBody: paddleResult.rawBody))
            return .ready(bandit: banditResponse, paddle: paddleResult)
        } catch {
            trackBffCompletion(priceId: priceId, transactionId: banditResponse.transactionId, scope: scope, startedAt: bffStart, chainStartedAt: chainStart, result: .failed(error))
            return .failed(error: error)
        }
    }

    /// Returns the postal code when the response's IP-geo is a US California
    /// ZIP (90001–96162, contiguous; HI starts at 96701). Nil otherwise.
    private nonisolated static func californiaPostalCode(in rawBody: Data) -> String? {
        guard let parsed = (try? JSONSerialization.jsonObject(with: rawBody)) as? [String: Any],
              let data = parsed["data"] as? [String: Any],
              (data["ip_geo_country_code"] as? String) == "US",
              let postal = data["ip_geo_postal_code"] as? String,
              let zip = Int(postal.prefix(5)),
              (90001...96162).contains(zip) else {
            return nil
        }
        return postal
    }
}
