import UIKit
import SafariServices

public class StripeCheckoutManager {
    public static let shared = ExternalWebCheckoutManager(
        provider: .stripe,
        entitlementsSource: HeliumEntitlementsManager.shared.stripeEntitlementsSource
    )
}
public class PaddleCheckoutManager {
    public static let shared = ExternalWebCheckoutManager(
        provider: .paddle,
        entitlementsSource: HeliumEntitlementsManager.shared.paddleEntitlementsSource
    )
}

/// Outcome of an attempted external web checkout flow.
enum WebCheckoutOutcome {
    /// Browser was opened; observation is pending until the user returns.
    case opened
    /// Pre-checkout entitlement check found the user already owns the product;
    /// browser was not opened and the flow is fully resolved.
    case preCheckResolved

    var transactionStatus: HeliumPaywallTransactionStatus {
        switch self {
        case .opened: return .pending
        case .preCheckResolved: return .restored
        }
    }
}

/// Orchestrates the external web checkout flow (browser-based) for payment providers.
public class ExternalWebCheckoutManager: NSObject {

    private let provider: PaymentProviderConfig
    private let entitlementsSource: HeliumPaymentEntitlementsSource

    // Checkout state
    private var foregroundObserver: NSObjectProtocol?
    private var foregroundCheckTask: Task<Void, Never>?
    private var pendingBackgroundObserver: NSObjectProtocol?

    // Server-managed checkout observation
    private struct CheckoutObservation {
        let paywallSession: PaywallSession
        let entitledProductIdsBeforeCheckout: Set<String>
        let addedAt: Date
    }
    // Usually there will only be one checkout per paywall but second try paywall would have
    // different paywall session and products, so track per session to be safer.
    private var activeCheckoutObservations: [String: CheckoutObservation] = [:]

    init(provider: PaymentProviderConfig, entitlementsSource: HeliumPaymentEntitlementsSource) {
        self.provider = provider
        self.entitlementsSource = entitlementsSource
        super.init()
    }

    // MARK: - Checkout Flow

    /// Builds the enriched checkout URL from the paywall's web bundle URL
    /// and opens it in an external browser, then starts observing for purchase completion.
    /// Returns `.opened` when the browser was launched, or `.preCheckResolved` if the
    /// pre-checkout entitlement check resolved the flow without opening the browser.
    @MainActor
    func startCheckoutFlow(
        for productKey: String,
        triggerName: String,
        paywallSession: PaywallSession
    ) async throws -> WebCheckoutOutcome {
        guard let resolvedSuccessURL = provider.getCheckoutSuccessURL(),
              let resolvedCancelURL = provider.getCheckoutCancelURL() else {
            throw WebCheckoutError.checkoutURLsNotConfigured
        }

        guard let bundleUrlString = paywallSession.paywallInfoWithBackups?.webPaywallBundleUrl,
              let baseURL = URL(string: bundleUrlString) else {
            throw WebCheckoutError.webPaywallBundleUrlMissing
        }

        let templateEvent = PurchaseSucceededEvent(
            productId: "",
            triggerName: triggerName,
            paywallName: paywallSession.paywallInfoWithBackups?.paywallTemplateName ?? "",
            storeKitTransactionId: nil,
            storeKitOriginalTransactionId: nil,
            paymentProcessor: provider.purchaseEventPaymentProcessor
        )
        let loggedEvent = HeliumAnalyticsManager.shared.buildLoggedEvent(
            for: templateEvent,
            paywallSession: paywallSession
        )

        // Paddle prefetch lookup: await EVERY priceId on the paywall
        // (not just the tapped one) before redirecting to Safari.
        // `collectPrefetchOutcomes` runs them in parallel via TaskGroup
        // with the per-priceId default timeout (3s), so wall-clock is
        // bounded by max(slowest priceId, 3s) — typically ~0ms when
        // the user has been reading the paywall for a few seconds.
        //
        // Why wait for non-tapped: the bundle in Safari can switch
        // products mid-flow. If a non-tapped priceId's bootstrap isn't
        // in ctx.paddleBootstraps when Safari opens, the bundle's
        // live-fetch path runs there instead — defeating the entire
        // "no loader on click" UX the prefetch exists to deliver. A
        // brief in-app wait before redirect is the explicit trade.
        //
        // Tapped-priceId-specific behavior:
        //   * .alreadyEntitled → short-circuit to .preCheckResolved (skip
        //     opening Safari to a guaranteed-failure UX). Other priceIds'
        //     alreadyEntitled outcomes do NOT short-circuit — they're
        //     just routed to ctx.paddleAlreadyEntitled so the bundle
        //     can short-circuit if the user picks that product in Safari.
        //   * .ready → encoded into the bootstraps map.
        //   * .failed / .notStarted → absent from the map; bundle's
        //     live-fetch path is the safety net.
        var paddleBootstrapsDict: [String: Any]? = nil
        var paddleAlreadyEntitledDict: [String: Any]? = nil
        if provider.providerSlug == "paddle",
           let tappedPriceId = PaddleCheckoutPrefetchCoordinator.extractPriceId(from: productKey) {
            let allPriceIds = PaddleCheckoutPrefetchCoordinator.extractPriceIds(
                from: paywallSession.paywallInfoWithBackups?.webProductsOfferedPaddle ?? []
            )
            // Defensive: ensure tapped is in the await set even if it
            // wasn't (somehow) in `webProductsOfferedPaddle`.
            let priceIdsToAwait = Array(Set(allPriceIds + [tappedPriceId]))

            let outcomes = await PaddleCheckoutPrefetchCoordinator.shared.collectPrefetchOutcomes(
                sessionId: paywallSession.sessionId,
                priceIds: priceIdsToAwait
            )

            // Tapped-product short-circuit fires only if the tapped product
            // itself is alreadyEntitled with a restorable code. Other
            // priceIds being entitled doesn't block this purchase, and
            // non-restorable codes (trial_already_used) flow through the
            // bundle for its failure-routing UX. See `tappedShortCircuit`
            // and `PaddleErrorCodes.isRestorable`.
            if let shortCircuit = PaddleCheckoutPrefetchCoordinator.tappedShortCircuit(
                in: outcomes, tappedPriceId: tappedPriceId
            ) {
                HeliumLogger.log(.debug, category: .entitlements,
                                 "\(provider.displayName) prefetch alreadyEntitled (\(shortCircuit.code)): \(shortCircuit.message) — skipping browser")
                // Same handling as the pre-checkout entitlement check
                // earlier in this method: no browser open, invalidate the
                // entitlements cache so future flows reflect the server's
                // view. The bundle still gets the existing-subscription-id
                // through ctx.paddleAlreadyEntitled for the non-tapped
                // paths' Jitsu fire; the tapped path resolves entirely
                // SDK-side and doesn't need the id locally.
                entitlementsSource.invalidateCache()
                return .preCheckResolved
            }

            paddleBootstrapsDict = PaddleCheckoutPrefetchCoordinator.encodeBootstrapsToCtx(
                outcomesByPriceId: outcomes
            )
            // Non-tapped products that came back .alreadyEntitled go
            // into a sibling map. Bundle uses it to short-circuit when
            // the user clicks one of these in Safari, avoiding the
            // bandit live-fetch (which would show a loader before
            // resolving to the same alreadyEntitled outcome).
            paddleAlreadyEntitledDict = PaddleCheckoutPrefetchCoordinator.encodeAlreadyEntitledToCtx(
                outcomesByPriceId: outcomes
            )
        }

        let enrichedURL = try buildEnrichedCheckoutURL(
            baseURL: baseURL,
            analyticsEvent: loggedEvent,
            productKey: productKey,
            triggerName: triggerName,
            successURL: resolvedSuccessURL,
            cancelURL: resolvedCancelURL,
            introOfferEligible: await isIntroOfferEligibleForWebCheckout(paywallInfo: paywallSession.paywallInfoWithBackups),
            paddleBootstraps: paddleBootstrapsDict,
            paddleAlreadyEntitled: paddleAlreadyEntitledDict
        )

        return try await openEnrichedCheckoutURL(enrichedURL, productKey: productKey, paywallSession: paywallSession)
    }


    /// True if every offered product is intro-offer eligible.
    /// Prefers the server's per-customer signal from `/check-entitlement` when
    /// available — the local price map can go stale (e.g., host app sets
    /// userId after Helium initialized, so eligibility could change).
    private func isIntroOfferEligibleForWebCheckout(paywallInfo: HeliumPaywallInfo?) async -> Bool {
        guard let paywallInfo,
              let products = provider.getOfferedProducts(paywallInfo, false),
              !products.isEmpty else {
            return false
        }
        if let serverValue = await entitlementsSource.introOfferEligible() {
            return serverValue
        }
        let priceMap = HeliumFetchedConfigManager.shared.getLocalizedPriceMap()
        return products.allSatisfy { priceMap[$0]?.subscriptionInfo?.introOfferEligible == true }
    }

    /// Appends analytics, identity, and routing parameters to a checkout URL
    /// as a single base64-encoded JSON `ctx` value, written to the URL
    /// **fragment** (after `#`), not the query string.
    ///
    /// **Why fragment, not query (HEL-5326 PII follow-up):** the ctx
    /// payload contains PII — `customer.email` (Paddle's record of a
    /// returning customer's email) and `ip_geo_postal_code` (Paddle's
    /// IP-derived postal code) per the Paddle privacy review.
    /// Hash fragments are **not sent in HTTP requests by browsers**, so
    /// they don't appear in CDN access logs, server access logs, or
    /// referer headers — exactly the leakage Paddle's privacy policy
    /// avoids.
    ///
    /// **Wire pairing:** the bundler-side decoder
    /// (`decodeCompressedCtxParam` in `heliumStandaloneStripe.ts`) reads
    /// `ctx` exclusively from the URL hash fragment. There is no legacy
    /// query-string wire to maintain — SDK and bundler ship hash-only.
    ///
    /// **Existing query items survive:** the bandit server appends
    /// `helium_ios_bundle_id=<id>` to the bundle URL as a query param
    /// for source_page attribution. This function preserves any
    /// pre-existing query items and only writes the fragment.
    ///
    /// `paddleBootstraps` (HEL-5326) is the SDK pre-fetch payload — a map
    /// keyed by priceId of bandit + Paddle BFF responses gathered during
    /// in-app paywall display. When non-nil, the bundle in Safari reads
    /// it from `ctx.paddleBootstraps[priceId]` for whichever product the
    /// user picks and skips its own bandit + BFF round-trips.
    ///
    /// `paddleAlreadyEntitled` is the sibling map for products bandit
    /// returned 409 `duplicate_subscription` for during pre-fetch.
    /// Bundle uses it to short-circuit straight to its
    /// `kind: 'alreadyEntitled'` branch when the user clicks one of
    /// these products in Safari — without it the bundle would have to
    /// call bandit itself just to discover the 409, with a loader
    /// showing during the round-trip.
    ///
    /// Pass nil for either when the SDK has nothing to report (e.g.
    /// Stripe path, prefetches that timed out). Bundle defaults to
    /// live-fetch on missing entries.
    func buildEnrichedCheckoutURL(
        baseURL: URL,
        analyticsEvent: HeliumPaywallLoggedEvent,
        productKey: String,
        triggerName: String,
        successURL: String,
        cancelURL: String,
        introOfferEligible: Bool,
        paddleBootstraps: [String: Any]? = nil,
        paddleAlreadyEntitled: [String: Any]? = nil
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw WebCheckoutError.failedToBuildEnrichedURL
        }

        var ctx: [String: Any] = [:]

        let analyticsData = try JSONEncoder().encode(analyticsEvent)
        let analyticsJSON = try JSONSerialization.jsonObject(with: analyticsData)
        ctx["analytics"] = analyticsJSON

        ctx[provider.initialProductKey] = productKey
        ctx["successUrl"] = successURL
        ctx["cancelUrl"] = cancelURL
        ctx["paymentFailureUrl"] = cancelURL // We currently do nothing special with paymentFailureUrl
        if let organizationId = HeliumFetchedConfigManager.shared.getOrganizationID() {
            ctx["organizationId"] = organizationId
        }
        ctx["introOfferEligible"] = introOfferEligible

        ctx["iosBundleId"] = Bundle.main.bundleIdentifier ?? "unknown"

        let baseBody = try HeliumPaymentAPIClient.shared.baseRequestBody(provider: provider)
        for (key, value) in baseBody where key != "apiKey" {
            if let stringValue = value as? String {
                ctx[key] = stringValue
            }
        }

        // SDK prefetch (HEL-5326): when present, the bundle in Safari
        // uses the pre-fetched responses for whichever product the user
        // picks (`ctx.paddleBootstraps[priceId]`) instead of making its
        // own bandit + BFF round-trips. See
        // `PaddleCheckoutPrefetchCoordinator.encodeBootstrapsToCtx` for
        // the wire contract.
        if let paddleBootstraps = paddleBootstraps {
            ctx["paddleBootstraps"] = paddleBootstraps
        }
        // Sibling map for products bandit returned 409 for. Bundle
        // short-circuits to its kind: 'alreadyEntitled' branch on click,
        // skipping the live bandit call (no loader, no round-trip).
        if let paddleAlreadyEntitled = paddleAlreadyEntitled {
            ctx["paddleAlreadyEntitled"] = paddleAlreadyEntitled
        }

        let ctxData = try JSONSerialization.data(withJSONObject: ctx)

        // Compress (raw DEFLATE / RFC 1951) then base64URL-encode. The
        // bundler decodes via fflate (Paddle bundles) or
        // `DecompressionStream('deflate-raw')` (Stripe bundles) — Apple's
        // `COMPRESSION_ZLIB` produces exactly that wire format despite
        // the name. See CtxCompression.swift for the wire-pairing
        // rationale.
        guard let compressed = CtxCompression.deflateRaw(ctxData) else {
            throw WebCheckoutError.failedToBuildEnrichedURL
        }

        // Append `helium_ios_bundle_id=<id>` as a query param when the
        // base URL doesn't already carry it. This aligns the actual
        // landing URL with the `source_page` value the SDK sends to
        // Paddle's `/transaction-checkout` (which is built by
        // `PaddleBFFClient.paddleSourcePage` as
        // `bundles.clickthrough.to?helium_ios_bundle_id=<id>`).
        // Approved as non-PII on the 2026-05-08 Paddle call —
        // identifies the app, not the user.
        //
        // Idempotent: if the bandit server (or some upstream) already
        // included `helium_ios_bundle_id` on the bundle URL, we
        // preserve the existing value rather than appending a
        // duplicate (URLComponents would happily produce
        // `?helium_ios_bundle_id=a&helium_ios_bundle_id=b`).
        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "helium_ios_bundle_id" }) {
            let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
            queryItems.append(URLQueryItem(name: "helium_ios_bundle_id", value: bundleId))
            components.queryItems = queryItems
        }

        // Write the compressed ctx to the URL fragment (after `#`), NOT
        // the query string. Browsers don't send fragments in HTTP
        // requests, so the ctx payload (which carries PII per HEL-5326
        // — Paddle's returning-customer email and IP-derived postal
        // code) doesn't leak through CDN logs, server access logs, or
        // referer headers. The bundler reads `ctx` exclusively from
        // `window.location.hash`; no query-string wire is supported.
        //
        // base64URL alphabet (RFC 4648 §5: A-Z, a-z, 0-9, -, _) is
        // entirely within RFC 3986's `unreserved` character set, so
        // setting `components.fragment` directly is safe — no
        // percent-encoding is applied to characters that don't need
        // it.
        components.fragment = "ctx=" + compressed.base64URLEncodedString()

        guard let url = components.url else {
            throw WebCheckoutError.failedToBuildEnrichedURL
        }
        return url
    }

    /// Opens the enriched checkout URL in external browser and starts observing
    /// for purchase completion via entitlements when the user returns to the app.
    /// Returns `.preCheckResolved` if cached entitlements already include `productKey`;
    /// otherwise `.opened`.
    @MainActor
    func openEnrichedCheckoutURL(_ url: URL, productKey: String, paywallSession: PaywallSession) async throws -> WebCheckoutOutcome {
        let entitledBefore = await entitlementsSource.purchasedHeliumProductIds()

        if entitledBefore.contains(productKey) {
            HeliumLogger.log(.debug, category: .entitlements, "\(provider.displayName) pre-checkout: user already entitled to \(productKey) — skipping browser")
            return .preCheckResolved
        }

        let observation = CheckoutObservation(
            paywallSession: paywallSession,
            entitledProductIdsBeforeCheckout: entitledBefore,
            addedAt: Date()
        )
        activeCheckoutObservations[paywallSession.sessionId] = observation

        let opened = await UIApplication.shared.open(url)
        guard opened else {
            activeCheckoutObservations.removeValue(forKey: paywallSession.sessionId)
            throw WebCheckoutError.failedToOpenEnrichedURL
        }
        startForegroundObserver()
        return .opened
    }

    /// Stops observing for purchase completion if the session matches.
    @MainActor
    func stopObserving(paywallSession: PaywallSession) {
        let removed = activeCheckoutObservations.removeValue(forKey: paywallSession.sessionId)
        if activeCheckoutObservations.isEmpty {
            foregroundCheckTask?.cancel()
            foregroundCheckTask = nil
            stopForegroundObserver()
            stopPendingBackgroundObserver()
        }
        // We're no longer auto-refreshing entitlements on foreground return for
        // this session, so a purchase that completed without us seeing it would
        // sit behind a stale cache. Force the next read to refetch.
        if removed != nil {
            entitlementsSource.invalidateCache()
        }
    }

    // MARK: - Foreground Observer

    private func startForegroundObserver() {
        stopForegroundObserver()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            onReturnedToForeground()
        }
    }

    private func stopForegroundObserver() {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        foregroundObserver = nil
    }

    /// Arms the foreground observer only once the app next enters the background.
    /// Used after a redirect lands while the app is still foregrounded — the
    /// already-scheduled didBecomeActive must not kick off a check, and we can't
    /// rely on URL-vs-didBecomeActive ordering. didEnterBackground is an
    /// unambiguous "user left the app" signal.
    @MainActor
    private func armForegroundObserverAfterBackground() {
        stopPendingBackgroundObserver()
        // If the app is already backgrounded (e.g. user backgrounded while we
        // were awaiting the post-redirect purchase check), didEnterBackground
        // won't fire again until they go foreground first — which is exactly
        // what we want to observe. Skip the indirection and arm the foreground
        // observer directly.
        if UIApplication.shared.applicationState == .background {
            guard !activeCheckoutObservations.isEmpty else { return }
            startForegroundObserver()
            return
        }
        pendingBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.stopPendingBackgroundObserver()
            guard !self.activeCheckoutObservations.isEmpty else { return }
            self.startForegroundObserver()
        }
    }

    private func stopPendingBackgroundObserver() {
        if let pendingBackgroundObserver {
            NotificationCenter.default.removeObserver(pendingBackgroundObserver)
        }
        pendingBackgroundObserver = nil
    }

    private func onReturnedToForeground() {
        guard !activeCheckoutObservations.isEmpty else { return }
        guard foregroundObserver != nil else { return }
        stopForegroundObserver()

        HeliumLogger.log(.debug, category: .entitlements, "Checking for new \(provider.displayName) entitlements...")

        foregroundCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.foregroundCheckTask = nil }

            let purchaseDetected = await checkForNewPurchaseWithRetry()
            if Task.isCancelled { return }

            // All retries exhausted — resume observing for next foreground return
            if !purchaseDetected && !activeCheckoutObservations.isEmpty {
                startForegroundObserver()
            }
        }
    }

    /// Runs `checkForNewPurchase` with a retry — entitlements may not be
    /// immediately available after an external purchase. Returns true if a
    /// purchase was detected.
    @MainActor
    private func checkForNewPurchaseWithRetry(fromSuccessRedirect: Bool = false) async -> Bool {
        let delays: [UInt64] = [0, 2_000_000_000]

        for (i, delay) in delays.enumerated() {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            if Task.isCancelled { return false }
            guard !activeCheckoutObservations.isEmpty else { return false }

            let purchaseDetected = await checkForNewPurchase(fromSuccessRedirect: fromSuccessRedirect)
            if Task.isCancelled { return false }
            HeliumLogger.log(.debug, category: .entitlements, "Detected new \(provider.displayName) purchase? \(purchaseDetected) (attempt #\(i + 1))")
            if purchaseDetected { return true }
        }
        return false
    }

    /// Refreshes entitlements once and scans active observations (newest-first).
    /// A newly-entitled offered product always fires `PurchaseSucceededEvent`.
    /// An already-entitled offered product fires `PurchaseRestoredEvent` only
    /// when `fromSuccessRedirect` is true (success-redirect path —
    /// positive evidence a checkout completed). On a generic foreground
    /// return, the restored path is suppressed to avoid spurious events when
    /// the user opens checkout for one product while already owning another
    /// offered on the same paywall. In either case, observations are cleared
    /// and paywalls hidden. Succeeded wins over Restored across all sessions.
    @MainActor
    private func checkForNewPurchase(fromSuccessRedirect: Bool = false) async -> Bool {
        await entitlementsSource.refreshEntitlements()
        let currentEntitledIds = await entitlementsSource.purchasedHeliumProductIds()
        HeliumLogger.log(.debug, category: .entitlements, "\(provider.displayName) checkForNewPurchase", metadata: [
            "observations": "\(activeCheckoutObservations.count)",
            "currentEntitledIds": "\(currentEntitledIds)"
        ])

        let observationsSnapshot = activeCheckoutObservations
            .sorted { $0.value.addedAt > $1.value.addedAt }

        var restoredCandidate: (productId: String, observation: CheckoutObservation)?

        for (sessionId, observation) in observationsSnapshot {
            guard let offeredProducts = observation.paywallSession.paywallInfoWithBackups.flatMap({ provider.getOfferedProducts($0, fromSuccessRedirect) }) else {
                // Skip, don't remove. Offered-products is static for the
                // observation's lifetime, so removing here would also kill the
                // redirect path where the in-app-set safety net would match.
                continue
            }

            let newlyEntitledIds = currentEntitledIds
                .subtracting(observation.entitledProductIdsBeforeCheckout)
            HeliumLogger.log(.debug, category: .entitlements, "\(provider.displayName) checkForNewPurchase session", metadata: [
                "sessionId": sessionId,
                "offered": "\(offeredProducts)",
                "newlyEntitled": "\(newlyEntitledIds)"
            ])

            // If multiple sessions offer the same product, attribute to the most
            // recently added session (likely the one the user just interacted with).
            // In practice, second-try paywalls offer different products.
            if let purchasedProductId = newlyEntitledIds.first(where: { offeredProducts.contains($0) }) {
                HeliumPaywallDelegateWrapper.shared.fireEvent(
                    PurchaseSucceededEvent(
                        productId: purchasedProductId,
                        triggerName: observation.paywallSession.trigger,
                        paywallName: observation.paywallSession.paywallInfoWithBackups?.paywallTemplateName ?? "",
                        storeKitTransactionId: nil,
                        storeKitOriginalTransactionId: nil,
                        paymentProcessor: provider.purchaseEventPaymentProcessor
                    ),
                    paywallSession: observation.paywallSession,
                    sendToAnalytics: false
                )
                activeCheckoutObservations.removeAll()
                Helium.shared.hideAllPaywalls()
                InlinePaywallDismissRegistry.dismissAll()
                return true
            }

            // Record newest session with an already-entitled offered product as a
            // restored candidate. Only fires if no session produces a Succeeded match
            // and the caller has positive evidence of checkout completion.
            if fromSuccessRedirect,
               restoredCandidate == nil,
               let entitledProductId = currentEntitledIds.first(where: { offeredProducts.contains($0) })  {
                restoredCandidate = (entitledProductId, observation)
            }
        }

        if let restored = restoredCandidate {
            HeliumPaywallDelegateWrapper.shared.fireEvent(
                PurchaseRestoredEvent(
                    productId: restored.productId,
                    triggerName: restored.observation.paywallSession.trigger,
                    paywallName: restored.observation.paywallSession.paywallInfoWithBackups?.paywallTemplateName ?? "",
                    restoreOrigin: .detectedPostWebCheckout,
                    paymentProcessor: provider.purchaseEventPaymentProcessor
                ),
                paywallSession: restored.observation.paywallSession,
                sendToAnalytics: false
            )
            activeCheckoutObservations.removeAll()
            Helium.shared.hideAllPaywalls()
            InlinePaywallDismissRegistry.dismissAll()
            return true
        }

        return false
    }

    /// Called when the host app forwards a Helium-tagged success/cancel redirect URL.
    /// Success: run `checkForNewPurchaseWithRetry` to handle both the newly-entitled
    /// and already-entitled cases, then re-arm the foreground observer for the next
    /// app return. Cancel: no-op on entitlements — the browser tab may still be open,
    /// so observations are kept and the foreground observer is re-armed so a later
    /// purchase still gets picked up on the next app return.
    @MainActor
    func handleExternalReturn(redirectKind: CheckoutRedirectKind) async {
        guard !activeCheckoutObservations.isEmpty else { return }

        // Redirect is authoritative — suppress the foreground-observer safety net
        // while we run explicit logic for this redirect.
        foregroundCheckTask?.cancel()
        foregroundCheckTask = nil
        stopForegroundObserver()

        switch redirectKind {
        case .success:
            HeliumLogger.log(.debug, category: .entitlements, "\(provider.displayName) success redirect handled — checking for new purchase")
            _ = await checkForNewPurchaseWithRetry(fromSuccessRedirect: true)
            if !activeCheckoutObservations.isEmpty {
                armForegroundObserverAfterBackground()
            }
        case .cancel:
            HeliumLogger.log(.debug, category: .entitlements, "\(provider.displayName) cancel redirect handled — observations kept in case user resumes checkout")
            armForegroundObserverAfterBackground()
        }
    }

    // Used by Stripe one-tap Apple Pay flow (so must be public)
    public func handleNewPurchase(productId: String, priceId: String?, subscriptionExpiresAt: Date?) {
        entitlementsSource.didCompletePurchase(productId: productId, priceId: priceId, subscriptionExpiresAt: subscriptionExpiresAt)
    }

    // MARK: - API Calls

    /// Syncs Stripe customer metadata with the current user identity.
    @discardableResult
    func updateCustomerMetadata(
        name: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        description: String? = nil
    ) async throws -> Bool {
        var body = try HeliumPaymentAPIClient.shared.baseRequestBody(provider: provider)
        body["metadata"] = [
            "userId": body["userId"] as? String ?? "",
            "rcUserId": body["rcUserId"] as? String ?? "",
            "heliumPersistentId": body["heliumPersistentId"] as? String ?? "",
            "appTransactionId": body["appTransactionId"] as? String ?? ""
        ]

        if let name { body["name"] = name }
        if let email { body["email"] = email }
        if let phone { body["phone"] = phone }
        if let description { body["description"] = description }

        let response: UpdateCustomerMetadataResponse = try await HeliumPaymentAPIClient.shared.post(provider.updateCustomerMetadataPath, body: body)
        if let customerId = response.customerId, provider.getCustomerId() == nil {
            provider.setCustomerId(customerId)
        }
        return response.updated ?? false
    }

    /// Creates a Customer Portal session and returns the portal URL.
    func createPortalSession(returnUrl: String? = nil) async throws -> URL {
        var body = try HeliumPaymentAPIClient.shared.baseRequestBody(provider: provider)
        if let returnUrl {
            body["returnUrl"] = returnUrl
        }

        let response: PortalSessionResponse = try await HeliumPaymentAPIClient.shared.post(provider.createPortalSessionPath, body: body)
        guard let portalUrl = response.portalUrl, let url = URL(string: portalUrl) else {
            throw HeliumPaymentAPIError.serverError(statusCode: 200, message: "No portal URL returned from the server.")
        }
        return url
    }
}

// MARK: - Base64URL

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
