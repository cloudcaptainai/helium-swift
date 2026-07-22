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

    let provider: PaymentProviderConfig
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
        return try await withFlowTelemetry(productKey: productKey, paywallSession: paywallSession) {
            try await self.runCheckoutFlow(
                for: productKey,
                triggerName: triggerName,
                paywallSession: paywallSession
            )
        }
    }

    @MainActor
    private func runCheckoutFlow(
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
            paymentProcessor: provider.kind
        )
        let loggedEvent = HeliumAnalyticsManager.shared.buildLoggedEvent(
            for: templateEvent,
            paywallSession: paywallSession
        )

        var paddleBootstrapsDict: [String: Any]? = nil
        var paddleAlreadyEntitledDict: [String: Any]? = nil
        if provider.kind == .paddle,
           let tappedPriceId = PaddleCheckoutPrefetchCoordinator.extractPriceId(from: productKey) {
            let allPriceIds = PaddleCheckoutPrefetchCoordinator.extractPriceIds(
                from: paywallSession.paywallInfoWithBackups?.webProductsOfferedPaddle ?? []
            )
            let priceIdsToAwait = Array(Set(allPriceIds + [tappedPriceId]))

            let awaitStart = Date()
            let outcomes = await PaddleCheckoutPrefetchCoordinator.shared.collectPrefetchOutcomes(
                sessionId: paywallSession.sessionId,
                priceIds: priceIdsToAwait
            )
            let awaitDurationMs = msSince(awaitStart)

            let shortCircuit = PaddleCheckoutPrefetchCoordinator.tappedShortCircuit(
                in: outcomes, tappedPriceId: tappedPriceId
            )
            emitPaddleAwaitResolved(
                tappedPriceId: tappedPriceId,
                awaitDurationMs: awaitDurationMs,
                outcomes: outcomes,
                shortCircuited: shortCircuit != nil,
                paywallSession: paywallSession
            )

            if let shortCircuit {
                HeliumLogger.log(.debug, category: .entitlements,
                                 "\(provider.displayName) prefetch alreadyEntitled (\(shortCircuit.code)): \(shortCircuit.message) — skipping browser")
                entitlementsSource.invalidateCache()
                return .preCheckResolved
            }

            if let caPostal = PaddleCheckoutPrefetchCoordinator.californiaBlockedPostalCode(in: outcomes) {
                HeliumLogger.log(.debug, category: .entitlements,
                                 "\(provider.displayName) prefetch blocked for California IP (postal \(caPostal)) — failing checkout")
                throw WebCheckoutError.californiaBuyerBlocked(postalCode: caPostal)
            }

            // Every offered product must be in a renderable state.
            let notReadyOffered = allPriceIds.filter { priceId in
                switch outcomes[priceId] ?? .notStarted {
                case .ready, .alreadyEntitled: return false
                case .failed, .notStarted: return true
                }
            }
            if !notReadyOffered.isEmpty {
                HeliumLogger.log(.debug, category: .entitlements,
                                 "\(provider.displayName) prefetch not ready for offered priceIds: \(notReadyOffered) — failing checkout")
                throw WebCheckoutError.paddlePrefetchNotReady(priceIds: notReadyOffered)
            }

            paddleBootstrapsDict = PaddleCheckoutPrefetchCoordinator.encodeBootstrapsToCtx(
                outcomesByPriceId: outcomes
            )
            paddleAlreadyEntitledDict = PaddleCheckoutPrefetchCoordinator.encodeAlreadyEntitledToCtx(
                outcomesByPriceId: outcomes
            )
        }

        var stripeIntroOfferEligibleByProduct: [String: Bool]? = nil
        if provider.kind == .stripe {
            stripeIntroOfferEligibleByProduct = buildStripeIntroOfferEligibleByProduct(
                paywallInfo: paywallSession.paywallInfoWithBackups
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
            paddleAlreadyEntitled: paddleAlreadyEntitledDict,
            stripeIntroOfferEligibleByProduct: stripeIntroOfferEligibleByProduct
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

    /// Stripe's intro-offer eligibility is genuinely per-product, so the web
    /// paywall needs the full map rather than the coarse `introOfferEligible` bool.
    /// Nil (nothing resolvable) leaves that coarse bool as the only signal.
    private func buildStripeIntroOfferEligibleByProduct(paywallInfo: HeliumPaywallInfo?) -> [String: Bool]? {
        guard let paywallInfo,
              let products = provider.getOfferedProducts(paywallInfo, false),
              !products.isEmpty,
              let priceMap = HeliumFetchedConfigManager.shared.getStripeProductsPriceMap() else {
            return nil
        }
        var eligibilityByProduct: [String: Bool] = [:]
        for productKey in products {
            if let eligible = priceMap[productKey]?.subscription?.introOfferEligible {
                eligibilityByProduct[productKey] = eligible
            }
        }
        return eligibilityByProduct.isEmpty ? nil : eligibilityByProduct
    }

    /// Builds the enriched checkout URL: existing query items are preserved,
    /// the compressed `ctx` payload is written to the URL fragment.
    func buildEnrichedCheckoutURL(
        baseURL: URL,
        analyticsEvent: HeliumPaywallLoggedEvent,
        productKey: String,
        triggerName: String,
        successURL: String,
        cancelURL: String,
        introOfferEligible: Bool,
        paddleBootstraps: [String: Any]? = nil,
        paddleAlreadyEntitled: [String: Any]? = nil,
        stripeIntroOfferEligibleByProduct: [String: Bool]? = nil
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw WebCheckoutError.invalidBaseURLForComponents
        }

        var ctx: [String: Any] = [:]

        let analyticsData = try JSONEncoder().encode(analyticsEvent)
        let analyticsJSON = try JSONSerialization.jsonObject(with: analyticsData)
        ctx["analytics"] = analyticsJSON
        
        var analyticsTopFields: [String: Any] = [:]
        if let userId = Helium.identify.userId {
            analyticsTopFields["userId"] = userId
        }
        if let segmentAnonymousId = HeliumAnalyticsManager.shared.getActiveAnalyticsInstance()?.anonymousId {
            analyticsTopFields["anonymousId"] = segmentAnonymousId
        }
        analyticsTopFields["context"] = SegmentContext.staticContextData()
        ctx["analyticsTopFields"] = analyticsTopFields

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

        if let paddleBootstraps = paddleBootstraps {
            ctx["paddleBootstraps"] = paddleBootstraps
        }
        if let paddleAlreadyEntitled = paddleAlreadyEntitled {
            ctx["paddleAlreadyEntitled"] = paddleAlreadyEntitled
        }
        if let stripeIntroOfferEligibleByProduct = stripeIntroOfferEligibleByProduct {
            ctx["stripeIntroOfferEligibleByProduct"] = stripeIntroOfferEligibleByProduct
        }

        let ctxData = try JSONSerialization.data(withJSONObject: ctx)

        guard let compressed = CtxCompression.deflateRaw(ctxData) else {
            throw WebCheckoutError.failedToCompressCtx
        }

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "helium_ios_bundle_id" }) {
            let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
            queryItems.append(URLQueryItem(name: "helium_ios_bundle_id", value: bundleId))
        }
        // Cache-bust per open: a fragment-only change doesn't reload the page,
        // so if the bundle is already open from a prior tap it would render
        // stale ctx (wrong selected product, stale entitled-banner state).
        // A unique query item forces a fresh navigation each time.
        queryItems.removeAll { $0.name == "hlm_ts" }
        queryItems.append(URLQueryItem(name: "hlm_ts", value: String(Int64(Date().timeIntervalSince1970 * 1000))))
        components.queryItems = queryItems

        components.fragment = "ctx=" + compressed.base64URLEncodedString()

        guard let url = components.url else {
            throw WebCheckoutError.failedToAssembleEnrichedURL
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
        HeliumObservabilityManager.shared.track(
            WebCheckoutBrowserOpenAttempted(provider: provider.providerSlug, success: opened),
            scope: paywallSession.observabilityScope
        )
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

        guard let newestObservation = activeCheckoutObservations.values.max(by: { $0.addedAt < $1.addedAt }) else {
            return false
        }
        let oldestOpenedAt = activeCheckoutObservations.values.min(by: { $0.addedAt < $1.addedAt })?.addedAt

        for (i, delay) in delays.enumerated() {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            if Task.isCancelled { return false }
            guard !activeCheckoutObservations.isEmpty else { return false }

            let purchaseDetected = await checkForNewPurchase(
                fromSuccessRedirect: fromSuccessRedirect,
                retryAttempt: i + 1
            )
            if Task.isCancelled { return false }
            HeliumLogger.log(.debug, category: .entitlements, "Detected new \(provider.displayName) purchase? \(purchaseDetected) (attempt #\(i + 1))")
            if purchaseDetected { return true }
        }
        HeliumObservabilityManager.shared.track(
            WebCheckoutPurchaseCheckExhausted(
                provider: provider.providerSlug,
                retries: delays.count,
                msSinceOpen: oldestOpenedAt.map { msSince($0) },
                fromSuccessRedirect: fromSuccessRedirect
            ),
            scope: newestObservation.paywallSession.observabilityScope
        )
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
    private func checkForNewPurchase(fromSuccessRedirect: Bool = false, retryAttempt: Int = 1) async -> Bool {
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
                        paymentProcessor: provider.kind
                    ),
                    paywallSession: observation.paywallSession,
                    sendToAnalytics: false
                )
                HeliumObservabilityManager.shared.track(
                    WebCheckoutPurchaseDetected(
                        provider: provider.providerSlug,
                        productId: purchasedProductId,
                        source: fromSuccessRedirect ? .successRedirect : .foregroundObserver,
                        retryAttempt: retryAttempt,
                        msSinceOpen: msSince(observation.addedAt),
                        wasRestore: false
                    ),
                    scope: observation.paywallSession.observabilityScope
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
                    paymentProcessor: provider.kind
                ),
                paywallSession: restored.observation.paywallSession,
                sendToAnalytics: false
            )
            HeliumObservabilityManager.shared.track(
                WebCheckoutPurchaseDetected(
                    provider: provider.providerSlug,
                    productId: restored.productId,
                    source: fromSuccessRedirect ? .successRedirect : .foregroundObserver,
                    retryAttempt: retryAttempt,
                    msSinceOpen: msSince(restored.observation.addedAt),
                    wasRestore: true
                ),
                scope: restored.observation.paywallSession.observabilityScope
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
    func handleExternalReturn(redirectKind: HeliumCheckoutRedirectType) async {
        guard let newest = activeCheckoutObservations.values.max(by: { $0.addedAt < $1.addedAt }) else {
            return
        }

        HeliumObservabilityManager.shared.track(
            WebCheckoutRedirectReceived(
                provider: provider.providerSlug,
                redirectKind: redirectKind.rawValue,
                msSinceOpen: msSince(newest.addedAt),
                observationCount: activeCheckoutObservations.count
            ),
            scope: newest.paywallSession.observabilityScope
        )

        // Redirect is authoritative — suppress the foreground-observer safety net
        // while we run explicit logic for this redirect.
        foregroundCheckTask?.cancel()
        foregroundCheckTask = nil
        stopForegroundObserver()

        switch redirectKind {
        case .success:
            HeliumLogger.log(.debug, category: .entitlements, "\(provider.displayName) success redirect handled — checking for new purchase")
            NotificationCenter.default.post(name: .heliumWebCheckoutProcessingChanged, object: nil, userInfo: ["visible": true])
            // Cap the spinner — a slow network call could leave app in unusable state.
            let overlayTimeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { return }
                NotificationCenter.default.post(name: .heliumWebCheckoutProcessingChanged, object: nil, userInfo: ["visible": false])
            }
            defer {
                overlayTimeoutTask.cancel()
                NotificationCenter.default.post(name: .heliumWebCheckoutProcessingChanged, object: nil, userInfo: ["visible": false])
            }
            _ = await checkForNewPurchaseWithRetry(fromSuccessRedirect: true)
            if !activeCheckoutObservations.isEmpty {
                armForegroundObserverAfterBackground()
            }
        case .cancel, .paymentFailure:
            HeliumLogger.log(.debug, category: .entitlements, "\(provider.displayName) \(redirectKind.rawValue) redirect handled — observations kept in case user resumes checkout")
            armForegroundObserverAfterBackground()
        }
    }

    // Used by Stripe one-tap Apple Pay flow (so must be public)
    public func handleNewPurchase(productId: String, priceId: String?, subscriptionExpiresAt: Date?) {
        entitlementsSource.didCompletePurchase(productId: productId, priceId: priceId, subscriptionExpiresAt: subscriptionExpiresAt)
    }

    // MARK: - API Calls

    /// Syncs customer metadata with the current user identity.
    @discardableResult
    func updateCustomerMetadata() async throws -> Bool {
        var body = try HeliumPaymentAPIClient.shared.baseRequestBody(provider: provider)
        body["metadata"] = [
            "userId": body["userId"] as? String ?? "",
            "rcUserId": body["rcUserId"] as? String ?? "",
            "heliumPersistentId": body["heliumPersistentId"] as? String ?? "",
            "appTransactionId": body["appTransactionId"] as? String ?? ""
        ]

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
