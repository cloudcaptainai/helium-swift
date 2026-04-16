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

/// Orchestrates the external web checkout flow (browser-based) for payment providers.
public class ExternalWebCheckoutManager: NSObject {

    private let provider: PaymentProviderConfig
    private let entitlementsSource: HeliumPaymentEntitlementsSource

    // Checkout state
    private var foregroundObserver: NSObjectProtocol?

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
    @MainActor
    func startCheckoutFlow(
        for productKey: String,
        triggerName: String,
        paywallSession: PaywallSession
    ) async throws {
        guard let resolvedSuccessURL = provider.getCheckoutSuccessURL(),
              let resolvedCancelURL = provider.getCheckoutCancelURL() else {
            throw WebCheckoutError.checkoutURLsNotConfigured
        }

        guard let bundleUrlString = paywallSession.paywallInfoWithBackups?.webPaywallBundleUrl,
              let baseURL = URL(string: bundleUrlString) else {
            throw WebCheckoutError.webPaywallBundleUrlMissing
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
            throw WebCheckoutError.failedToBuildEnrichedURL
        }

        var ctx: [String: Any] = [:]

        let analyticsData = try JSONEncoder().encode(analyticsEvent)
        let analyticsJSON = try JSONSerialization.jsonObject(with: analyticsData)
        ctx["analytics"] = analyticsJSON

        ctx["initialStripeSelection"] = productKey
        ctx["trigger"] = triggerName
        ctx["successUrl"] = successURL
        ctx["cancelUrl"] = cancelURL

        let baseBody = try HeliumPaymentAPIClient.shared.baseRequestBody(provider: provider)
        for (key, value) in baseBody where key != "apiKey" {
            if let stringValue = value as? String {
                ctx[key] = stringValue
            }
        }

        let ctxData = try JSONSerialization.data(withJSONObject: ctx)
        let ctxBase64 = ctxData.base64URLEncodedString()

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "ctx", value: ctxBase64))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw WebCheckoutError.failedToBuildEnrichedURL
        }
        return url
    }

    /// Opens the enriched checkout URL in external browser and starts observing
    /// for purchase completion via entitlements when the user returns to the app.
    @MainActor
    func openEnrichedCheckoutURL(_ url: URL, paywallSession: PaywallSession) async throws {
        let entitledBefore = await entitlementsSource.purchasedHeliumProductIds()
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

        HeliumLogger.log(.debug, category: .entitlements, "Checking for new \(provider.displayName) entitlements...")

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Entitlements may not be immediately available after an external purchase.
            // Retry a few times (if needed) with increasing delays.
            let delays: [UInt64] = [0, 2_000_000_000, 3_000_000_000, 5_000_000_000]

            for (i, delay) in delays.enumerated() {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !activeCheckoutObservations.isEmpty else { return }

                await entitlementsSource.refreshEntitlements()
                let currentEntitledIds = await entitlementsSource.purchasedHeliumProductIds()

                var purchaseDetected = false
                let observationsSnapshot = activeCheckoutObservations
                    .sorted { $0.value.addedAt > $1.value.addedAt }
                for (sessionId, observation) in observationsSnapshot {
                    guard let offeredProducts = observation.paywallSession.paywallInfoWithBackups.flatMap({ provider.getOfferedProducts($0) }) else {
                        activeCheckoutObservations.removeValue(forKey: sessionId)
                        continue
                    }

                    let newlyEntitledIds = currentEntitledIds
                        .subtracting(observation.entitledProductIdsBeforeCheckout)

                    // If multiple sessions offer the same product, we attribute to the most
                    // recently added session (likely the one the user just interacted with).
                    // In practice, second-try paywalls offer different products.
                    if let purchasedProductId = newlyEntitledIds.first(where: { offeredProducts.contains($0) }) {
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

                HeliumLogger.log(.debug, category: .entitlements, "Detected new \(provider.displayName) purchase? \(purchaseDetected) (attempt #\(i + 1))")

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
    func createPortalSession(returnUrl: String) async throws -> URL {
        var body = try HeliumPaymentAPIClient.shared.baseRequestBody(provider: provider)
        body["returnUrl"] = returnUrl

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
