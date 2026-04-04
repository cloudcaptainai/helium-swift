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
    private var observingPaywallSession: PaywallSession?

    private override init() {
        super.init()
    }

    deinit {
        purchaseContinuation?.resume(returning: .cancelled)
    }

    /// Starts observing `didBecomeActive` for pending checkout recovery.
    /// Called after the SDK is initialized and the API key is available.
    func startPendingCheckoutRecovery() {
        resolvePendingCheckoutIfNeeded()

        guard appDidBecomeActiveObserver == nil else { return }
        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resolvePendingCheckoutIfNeeded()
        }
    }

    // MARK: - Checkout Flow

    /// Creates a Stripe Checkout session and returns the checkout URL and metadata
    /// without presenting it. The caller is responsible for enriching the URL and
    /// calling `openEnrichedCheckoutURL` to present.
    @MainActor
    func presentCheckoutFlow(
        for productId: String
    ) async -> CheckoutFlowResult {
        guard let resolvedSuccessURL = Helium.config.stripeCheckoutSuccessURL,
              let resolvedCancelURL = Helium.config.stripeCheckoutCancelURL else {
            return .clientManaged(.failed(StripeCheckoutError.checkoutURLsNotConfigured))
        }

        let checkoutURL: URL
        let sessionId: String
        do {
            let result = try await createCheckoutSession(
                productPriceId: productId,
                successURL: resolvedSuccessURL,
                cancelURL: resolvedCancelURL
            )
            checkoutURL = result.checkoutURL
            sessionId = result.sessionId
        } catch {
            return .clientManaged(.failed(error))
        }

        currentSessionId = sessionId

        return .serverManaged(checkoutURL: checkoutURL, successURL: resolvedSuccessURL, cancelURL: resolvedCancelURL)
    }

    /// Appends analytics, identity, and routing query parameters to a checkout URL.
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

        var queryItems = components.queryItems ?? []

        let jsonData = try JSONEncoder().encode(analyticsEvent)
        queryItems.append(URLQueryItem(name: "analyticsProperties", value: jsonData.base64EncodedString()))

        queryItems.append(URLQueryItem(name: "productKey", value: productKey))
        queryItems.append(URLQueryItem(name: "trigger", value: triggerName))
        queryItems.append(URLQueryItem(name: "successUrl", value: successURL))
        queryItems.append(URLQueryItem(name: "cancelUrl", value: cancelURL))

        let baseBody = HeliumStripeAPIClient.shared.baseRequestBody()
        for (key, value) in baseBody where key != "apiKey" {
            if let stringValue = value as? String {
                queryItems.append(URLQueryItem(name: key, value: stringValue))
            }
        }

        components.queryItems = queryItems
        guard let url = components.url else {
            throw StripeCheckoutError.failedToBuildEnrichedURL
        }
        return url
    }

    /// Opens the enriched checkout URL in external browser and starts observing
    /// for purchase completion via entitlements when the user returns to the app.
    @MainActor
    func openEnrichedCheckoutURL(_ url: URL, paywallSession: PaywallSession) {
        observingPaywallSession = paywallSession
        UIApplication.shared.open(url)
        startForegroundObserver()
    }

    /// Stops observing for purchase completion if the session matches.
    func stopObserving(paywallSession: PaywallSession) {
        guard observingPaywallSession?.sessionId == paywallSession.sessionId else { return }
        stopForegroundObserver()
        observingPaywallSession = nil
    }

    /// Returns the latest transaction ID result after a successful checkout.
    public func getLatestTransactionResult() -> HeliumTransactionIdResult? {
        return latestTransactionResult
    }

    // MARK: - Presentation Modes

    @MainActor
    private func presentWebViewCheckout(checkoutURL: URL) async -> sending HeliumPaywallTransactionStatus {
        guard let topVC = UIWindowHelper.findTopMostViewController() else {
            return .failed(StripeCheckoutError.cannotPresentCheckout)
        }

        return await withCheckedContinuation { continuation in
            self.purchaseContinuation = continuation
            let checkoutVC = StripeCheckoutViewController(checkoutURL: checkoutURL) { [weak self] result in
                guard let self else { return }
                completeCheckout(result: result)
            }
            topVC.present(checkoutVC, animated: true)
        }
    }

    @MainActor
    private func presentSafariCheckout(checkoutURL: URL) async -> sending HeliumPaywallTransactionStatus {
        guard let topVC = UIWindowHelper.findTopMostViewController() else {
            return .failed(StripeCheckoutError.cannotPresentCheckout)
        }

        let safariVC = SFSafariViewController(url: checkoutURL)
        safariVC.delegate = self

        return await withCheckedContinuation { continuation in
            self.purchaseContinuation = continuation
            topVC.present(safariVC, animated: true)
        }
    }

    @MainActor
    private func presentExternalBrowserCheckout(checkoutURL: URL) async -> sending HeliumPaywallTransactionStatus {
        let opened = await UIApplication.shared.open(checkoutURL)
        guard opened else {
            PendingCheckout.clear()
            return .failed(StripeCheckoutError.cannotPresentCheckout)
        }

        return await withCheckedContinuation { continuation in
            self.purchaseContinuation = continuation
            startForegroundObserver()
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
        guard let paywallSession = observingPaywallSession else { return }
        guard foregroundObserver != nil else { return }
        stopForegroundObserver()

        Task { [weak self] in
            guard let self else { return }
            guard let stripeProducts = paywallSession.paywallInfoWithBackups?.productsOfferedStripe else {
                return
            }
            await HeliumEntitlementsManager.shared.stripeEntitlementsSource.refreshEntitlements()
            
            let entitledStripeProductIds = await HeliumEntitlementsManager.shared.stripeEntitlementsSource.purchasedHeliumProductIds()
            let isEntitled = entitledStripeProductIds.contains { stripeProducts.contains($0) }
            if isEntitled {
                observingPaywallSession = nil
                HeliumPaywallDelegateWrapper.shared.fireEvent(
                    PurchaseSucceededEvent(
                        productId: "",
                        triggerName: paywallSession.trigger,
                        paywallName: paywallSession.paywallInfoWithBackups?.paywallTemplateName ?? "",
                        storeKitTransactionId: nil,
                        storeKitOriginalTransactionId: nil
                    ),
                    paywallSession: paywallSession,
                    sendToAnalytics: false
                )
            } else {
                // Not entitled yet — resume observing for next foreground return
                startForegroundObserver()
            }
        }
    }

    private func onSafariViewControllerDismissed() {
        guard let sessionId = currentSessionId, purchaseContinuation != nil else { return }
        confirmActiveSession(sessionId: sessionId)
    }

    private func confirmActiveSession(sessionId: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await confirmAndFulfill(sessionId: sessionId)
                await MainActor.run {
                    if let topVC = UIWindowHelper.findTopMostViewController(), topVC is SFSafariViewController {
                        topVC.dismiss(animated: true)
                    }
                }
                resumePurchase(with: .purchased)
            } catch StripeCheckoutError.confirmationAlreadyInProgress {
                // Another caller is already confirming — let it handle the result.
            } catch HeliumStripeAPIError.checkoutSessionNotCompleted {
                // Session not completed yet — don't clear pending state,
                // user may return to the browser to finish checkout.
                resumePurchase(with: .cancelled)
            } catch {
                // Network/server error — don't clear pending state, keep it for retry
                resumePurchase(with: .failed(error))
            }
        }
    }

    // MARK: - Pending Checkout Recovery (app terminated)

    /// Resolves any pending checkout that was in progress when the app was terminated or backgrounded.
    /// Debounced to avoid excessive API calls on rapid foreground events.
    func resolvePendingCheckoutIfNeeded() {
        if let lastResolve = lastPendingCheckoutResolveTime,
           Date().timeIntervalSince(lastResolve) < Self.pendingCheckoutResolveCooldown {
            return
        }

        guard purchaseContinuation == nil else { return }
        guard let pending = PendingCheckout.load() else { return }
        guard !pending.isExpired else {
            PendingCheckout.clear()
            return
        }

        lastPendingCheckoutResolveTime = Date()

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await confirmAndFulfill(sessionId: pending.sessionId)

                HeliumPaywallDelegateWrapper.shared.fireEvent(
                    PurchaseSucceededEvent(
                        productId: result.productId,
                        triggerName: pending.triggerName,
                        paywallName: pending.paywallName,
                        storeKitTransactionId: result.transactionId,
                        storeKitOriginalTransactionId: result.transactionId
                    ),
                    paywallSessionId: pending.paywallSessionId
                )
            } catch {
                // Session wasn't completed — nothing to recover
            }
        }
    }

    // MARK: - Checkout Completion

    private func completeCheckout(result: StripeCheckoutResult) {
        guard let sessionId = currentSessionId else { return }

        switch result {
        case .success(let returnedSessionId):
            let resolvedSessionId = returnedSessionId ?? sessionId
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await confirmAndFulfill(sessionId: resolvedSessionId)
                    resumePurchase(with: .purchased)
                } catch StripeCheckoutError.confirmationAlreadyInProgress {
                    // Another caller is already confirming — let it handle the result.
                } catch {
                    resumePurchase(with: .failed(error))
                }
            }
        case .cancelled:
            resumePurchase(with: .cancelled)
        case .failed(let error):
            resumePurchase(with: .failed(error))
        }
    }

    private func resumePurchase(with status: sending HeliumPaywallTransactionStatus) {
        stopForegroundObserver()
        purchaseContinuation?.resume(returning: status)
        purchaseContinuation = nil
        currentSessionId = nil
    }

    // MARK: - Shared Confirmation Logic

    /// Confirms the session, stores the transaction result, and notifies entitlements.
    /// Returns the confirmed transaction ID.
    @discardableResult
    private func confirmAndFulfill(sessionId: String) async throws -> (productId: String, transactionId: String) {
        let didClaim = _confirmingSessionIds.withValue { ids -> Bool in
            ids.insert(sessionId).inserted
        }
        guard didClaim else {
            throw StripeCheckoutError.confirmationAlreadyInProgress
        }
        defer { _confirmingSessionIds.withValue { $0.remove(sessionId) } }

        let confirmation = try await confirmCheckoutSession(sessionId: sessionId)
        PendingCheckout.clearIfMatches(sessionId: sessionId)
        
        var heliumProductId = confirmation.productId
        if let priceId = confirmation.priceId {
            heliumProductId += ":\(priceId)"
        }
        let txnId = confirmation.transactionId ?? sessionId
        latestTransactionResult = HeliumTransactionIdResult(
            productId: heliumProductId,
            transactionId: txnId,
            originalTransactionId: txnId
        )
        HeliumEntitlementsManager.shared.stripeEntitlementsSource.didCompletePurchase(
            productId: confirmation.productId,
            priceId: confirmation.priceId,
            subscriptionExpiresAt: confirmation.expiresAt
        )
        return (productId: confirmation.productId, transactionId: txnId)
    }

    // MARK: - API Calls

    /// Creates a Stripe Checkout Session and returns the hosted checkout URL.
    func createCheckoutSession(
        productPriceId: String,
        successURL: String,
        cancelURL: String
    ) async throws -> (checkoutURL: URL, sessionId: String) {
        var body = HeliumStripeAPIClient.shared.baseRequestBody(productId: productPriceId)
        body["successUrl"] = successURL
        body["cancelUrl"] = cancelURL

        let response: CheckoutSessionResponse = try await HeliumStripeAPIClient.shared.post("stripe/create-checkout-session", body: body)
        if let stripeCustomerId = response.stripeCustomerId {
            HeliumIdentityManager.shared.setStripeCustomerId(stripeCustomerId)
        }
        guard let checkoutUrlString = response.checkoutURL, let url = URL(string: checkoutUrlString) else {
            throw HeliumStripeAPIError.serverError(statusCode: 200, message: "No checkout URL returned from the server.")
        }
        guard let sessionId = response.sessionId, !sessionId.isEmpty else {
            throw HeliumStripeAPIError.serverError(statusCode: 200, message: "No session ID returned from the server.")
        }
        return (checkoutURL: url, sessionId: sessionId)
    }

    /// Confirms a completed Stripe Checkout Session and returns the purchase details.
    /// Throws if the session has not been completed yet.
    func confirmCheckoutSession(sessionId: String) async throws -> PaymentSuccessResponse {
        var body = HeliumStripeAPIClient.shared.baseRequestBody()
        body["sessionId"] = sessionId

        let response: ExecutePurchaseResponse
        do {
            response = try await HeliumStripeAPIClient.shared.post("stripe/confirm-checkout", body: body)
        } catch HeliumStripeAPIError.serverError(let statusCode, let message) where statusCode == 400 && message.contains("session_not_complete") {
            throw HeliumStripeAPIError.checkoutSessionNotCompleted
        }

        guard response.status == "complete" || response.transactionId != nil else {
            throw HeliumStripeAPIError.checkoutSessionNotCompleted
        }

        return response.toPaymentSuccessResponse()
    }

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

// MARK: - SFSafariViewControllerDelegate

extension StripeCheckoutManager: SFSafariViewControllerDelegate {
    public func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        // Note that we specifically avoid foreground listener here because it can incorrectly fire any time app becomes
        // active even if safari view controller still showing.
        onSafariViewControllerDismissed()
    }
}

// MARK: - Error

enum StripeCheckoutError: LocalizedError {
    case cannotPresentCheckout
    case notInitialized
    case checkoutURLsNotConfigured
    case confirmationAlreadyInProgress
    case failedToBuildEnrichedURL

    var errorDescription: String? {
        switch self {
        case .cannotPresentCheckout:
            return "Could not present the checkout view"
        case .notInitialized:
            return "Stripe checkout is not initialized. Call initializeWithStripeOneTap() or configure StripeCheckoutManager first."
        case .checkoutURLsNotConfigured:
            return "Stripe Checkout URLs not configured. Call Helium.config.enableStripeCheckout(successURL:cancelURL:) before presenting a paywall."
        case .confirmationAlreadyInProgress:
            return "A checkout confirmation is already in progress."
        case .failedToBuildEnrichedURL:
            return "Failed to build enriched checkout URL."
        }
    }
}
