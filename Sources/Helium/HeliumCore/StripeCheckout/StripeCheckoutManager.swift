import UIKit
import SafariServices

/// Orchestrates the Stripe app2web checkout flow (WebView, Safari, external browser).
public class StripeCheckoutManager: NSObject {

    public static let shared = StripeCheckoutManager()

    // Checkout state
    private var currentSessionId: String?
    private var purchaseContinuation: CheckedContinuation<HeliumPaywallTransactionStatus, Never>?
    private var latestTransactionResult: HeliumTransactionIdResult?
    private var foregroundObserver: NSObjectProtocol?
    @HeliumAtomic private var confirmingSessionIds: Set<String> = []
    private var lastPendingCheckoutResolveTime: Date?
    private static let pendingCheckoutResolveCooldown: TimeInterval = 30

    private var appDidBecomeActiveObserver: NSObjectProtocol?

    // Server-managed checkout observation
    private struct CheckoutObservation {
        let paywallSession: PaywallSession
        let entitledProductIdsBeforeCheckout: Set<String>
    }
    // Usually there will only be one checkout per paywall but second try paywall would have
    // different paywall session and products, so track per session to be safer.
    private var activeCheckoutObservations: [String: CheckoutObservation] = [:]

    private override init() {
        super.init()
    }

    deinit {
        purchaseContinuation?.resume(returning: .cancelled)
    }

    // MARK: - Checkout Flow

    /// Builds the enriched checkout URL from the paywall's web bundle URL
    /// and opens it in an external browser, then starts observing for purchase completion.
    @MainActor
    func startCheckoutFlow(
        for productKey: String,
        triggerName: String,
        paywallSession: PaywallSession
    ) async throws {
        guard let resolvedSuccessURL = Helium.config.stripeCheckoutSuccessURL,
              let resolvedCancelURL = Helium.config.stripeCheckoutCancelURL else {
            throw StripeCheckoutError.checkoutURLsNotConfigured
        }

        guard let bundleUrlString = paywallSession.paywallInfoWithBackups?.webPaywallBundleUrl,
              let baseURL = URL(string: bundleUrlString) else {
            throw StripeCheckoutError.webPaywallBundleUrlMissing
        }

        let templateEvent = PurchaseSucceededEvent(
            productId: productKey,
            triggerName: triggerName,
            paywallName: paywallSession.paywallInfoWithBackups?.paywallTemplateName ?? "",
            storeKitTransactionId: nil,
            storeKitOriginalTransactionId: nil
        )
        let loggedEvent = HeliumAnalyticsManager.shared.buildLoggedEvent(
            for: templateEvent,
            paywallSession: paywallSession
        )

        let enrichedURL = try buildEnrichedCheckoutURL(
            baseURL: baseURL,
            analyticsEvent: loggedEvent,
            productKey: productKey,
            triggerName: triggerName,
            successURL: resolvedSuccessURL,
            cancelURL: resolvedCancelURL
        )

        try await openEnrichedCheckoutURL(enrichedURL, paywallSession: paywallSession)
    }

    /// Appends analytics, identity, and routing query parameters to a checkout URL
    /// as a single base64-encoded JSON `ctx` query parameter.
    func buildEnrichedCheckoutURL(
        baseURL: URL,
        analyticsEvent: HeliumPaywallLoggedEvent,
        productKey: String,
        triggerName: String,
        successURL: String,
        cancelURL: String
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw StripeCheckoutError.failedToBuildEnrichedURL
        }

        var ctx: [String: Any] = [:]

        let analyticsData = try JSONEncoder().encode(analyticsEvent)
        ctx["analytics"] = analyticsData.base64EncodedString()

        ctx["initialStripeSelection"] = productKey
        ctx["trigger"] = triggerName
        ctx["successUrl"] = successURL
        ctx["cancelUrl"] = cancelURL

        let baseBody = HeliumStripeAPIClient.shared.baseRequestBody()
        for (key, value) in baseBody where key != "apiKey" {
            if let stringValue = value as? String {
                ctx[key] = stringValue
            }
        }

        let ctxData = try JSONSerialization.data(withJSONObject: ctx)
        let ctxBase64 = ctxData.base64EncodedString()

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "ctx", value: ctxBase64))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw StripeCheckoutError.failedToBuildEnrichedURL
        }
        return url
    }

    /// Opens the enriched checkout URL in external browser and starts observing
    /// for purchase completion via entitlements when the user returns to the app.
    @MainActor
    func openEnrichedCheckoutURL(_ url: URL, paywallSession: PaywallSession) async throws {
        let entitledBefore = await HeliumEntitlementsManager.shared.stripeEntitlementsSource.purchasedHeliumProductIds()
        let observation = CheckoutObservation(
            paywallSession: paywallSession,
            entitledProductIdsBeforeCheckout: entitledBefore
        )
        activeCheckoutObservations[paywallSession.sessionId] = observation

        let opened = await UIApplication.shared.open(url)
        guard opened else {
            activeCheckoutObservations.removeValue(forKey: paywallSession.sessionId)
            throw StripeCheckoutError.failedToOpenEnrichedURL
        }
        startForegroundObserver()
    }

    /// Stops observing for purchase completion if the session matches.
    @MainActor
    func stopObserving(paywallSession: PaywallSession) {
        activeCheckoutObservations.removeValue(forKey: paywallSession.sessionId)
        if activeCheckoutObservations.isEmpty {
            stopForegroundObserver()
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

    private func onReturnedToForeground() {
        guard !activeCheckoutObservations.isEmpty else { return }
        guard foregroundObserver != nil else { return }
        stopForegroundObserver()

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Stripe entitlements may not be available immediately after an external purchase.
            // Wait 2s before the first check, then retry up to 2 more times with 3s delays
            // (8s total delay, not counting request time).
            let delays: [UInt64] = [2_000_000_000, 3_000_000_000, 3_000_000_000]

            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)
                guard !activeCheckoutObservations.isEmpty else { return }

                await HeliumEntitlementsManager.shared.stripeEntitlementsSource.refreshEntitlements()
                let currentEntitledIds = await HeliumEntitlementsManager.shared.stripeEntitlementsSource.purchasedHeliumProductIds()

                var purchaseDetected = false
                let observationsSnapshot = activeCheckoutObservations
                for (sessionId, observation) in observationsSnapshot {
                    guard let stripeProducts = observation.paywallSession.paywallInfoWithBackups?.productsOfferedStripe else {
                        activeCheckoutObservations.removeValue(forKey: sessionId)
                        continue
                    }

                    let newlyEntitledIds = currentEntitledIds
                        .subtracting(observation.entitledProductIdsBeforeCheckout)

                    if let purchasedProductId = newlyEntitledIds.first(where: { stripeProducts.contains($0) }) {
                        purchaseDetected = true
                        HeliumPaywallDelegateWrapper.shared.fireEvent(
                            PurchaseSucceededEvent(
                                productId: purchasedProductId,
                                triggerName: observation.paywallSession.trigger,
                                paywallName: observation.paywallSession.paywallInfoWithBackups?.paywallTemplateName ?? "",
                                storeKitTransactionId: nil,
                                storeKitOriginalTransactionId: nil
                            ),
                            paywallSession: observation.paywallSession,
                            sendToAnalytics: false
                        )
                        break
                    }
                }

                if purchaseDetected {
                    activeCheckoutObservations.removeAll()
                    // TODO: Ideally call HeliumActionsDelegate.dismissAll to handle dismissAction for DynamicPaywallModifier case...
                    Helium.shared.hideAllPaywalls()
                    return
                }
            }

            // All retries exhausted — resume observing for next foreground return
            if !activeCheckoutObservations.isEmpty {
                startForegroundObserver()
            }
        }
    }

    // MARK: - API Calls

    /// Syncs Stripe customer metadata with the current user identity.
    @discardableResult
    public func updateCustomerMetadata(
        name: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        description: String? = nil
    ) async throws -> Bool {
        var body = HeliumStripeAPIClient.shared.baseRequestBody()
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

        let response: UpdateCustomerMetadataResponse = try await HeliumStripeAPIClient.shared.post("stripe/update-customer-metadata", body: body)
        if let customerId = response.customerId, HeliumIdentityManager.shared.getStripeCustomerId() == nil {
            HeliumIdentityManager.shared.setStripeCustomerId(customerId)
        }
        return response.updated ?? false
    }

    /// Creates a Stripe Customer Portal session and returns the portal URL.
    public func createPortalSession(returnUrl: String) async throws -> URL {
        var body = HeliumStripeAPIClient.shared.baseRequestBody()
        body["returnUrl"] = returnUrl

        let response: PortalSessionResponse = try await HeliumStripeAPIClient.shared.post("stripe/create-portal-session", body: body)
        guard let portalUrl = response.portalUrl, let url = URL(string: portalUrl) else {
            throw HeliumStripeAPIError.serverError(statusCode: 200, message: "No portal URL returned from the server.")
        }
        return url
    }
}

// MARK: - Error

enum StripeCheckoutError: LocalizedError {
    case cannotPresentCheckout
    case checkoutURLsNotConfigured
    case failedToBuildEnrichedURL
    case failedToOpenEnrichedURL
    case webPaywallBundleUrlMissing

    var errorDescription: String? {
        switch self {
        case .cannotPresentCheckout:
            return "Could not present the checkout view"
        case .checkoutURLsNotConfigured:
            return "Stripe Checkout URLs not configured. Call Helium.config.enableStripeCheckout(successURL:cancelURL:) before presenting a paywall."
        case .failedToBuildEnrichedURL:
            return "Failed to build enriched checkout URL."
        case .failedToOpenEnrichedURL:
            return "Could not open enriched checkout URL in browser."
        case .webPaywallBundleUrlMissing:
            return "No web paywall bundle URL available for this paywall."
        }
    }
}
