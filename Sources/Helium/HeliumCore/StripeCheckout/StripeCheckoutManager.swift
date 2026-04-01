import UIKit
import SafariServices

/// Orchestrates the Stripe app2web checkout flow (WebView, Safari, external browser).
public class StripeCheckoutManager: NSObject, @unchecked Sendable {

    public static let shared = StripeCheckoutManager()

    private var entitlementsSource: ThirdPartyEntitlementsSource?

    // Checkout state
    private var currentProductId: String?
    private var currentSessionId: String?
    private var purchaseContinuation: CheckedContinuation<HeliumPaywallTransactionStatus, Never>?
    private var latestTransactionResult: HeliumTransactionIdResult?
    private var foregroundObserver: NSObjectProtocol?

    private override init() {
        super.init()
    }

    deinit {
        purchaseContinuation?.resume(returning: .cancelled)
    }

    // MARK: - Configuration

    /// Called during initialization (e.g. from `initializeWithStripeOneTap`) to wire up the entitlements source.
    public func configure(entitlementsSource: ThirdPartyEntitlementsSource?) {
        self.entitlementsSource = entitlementsSource
    }

    // MARK: - Public Checkout Flow

    /// Presents the Stripe Checkout flow using the specified style.
    /// Returns the transaction status when checkout completes.
    @MainActor
    public func presentCheckoutFlow(
        for productId: String,
        style: StripeCheckoutStyle?,
        successURL: String?,
        cancelURL: String?
    ) async -> sending HeliumPaywallTransactionStatus {
        let resolvedStyle = style ?? .webView
        let resolvedSuccessURL = successURL ?? StripeCheckoutRedirect.successURL
        let resolvedCancelURL = cancelURL ?? StripeCheckoutRedirect.cancelURL

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
            return .failed(error)
        }

        currentProductId = productId
        currentSessionId = sessionId

        switch resolvedStyle {
        case .webView:
            return await presentWebViewCheckout(checkoutURL: checkoutURL)
        case .safariInApp:
            PendingCheckout.save(PendingCheckout(productId: productId, sessionId: sessionId, timestamp: Date()))
            return await presentSafariCheckout(checkoutURL: checkoutURL)
        case .externalBrowser:
            PendingCheckout.save(PendingCheckout(productId: productId, sessionId: sessionId, timestamp: Date()))
            return await presentExternalBrowserCheckout(checkoutURL: checkoutURL)
        }
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
            startForegroundObserver()
            topVC.present(safariVC, animated: true)
        }
    }

    @MainActor
    private func presentExternalBrowserCheckout(checkoutURL: URL) async -> sending HeliumPaywallTransactionStatus {
        await UIApplication.shared.open(checkoutURL)

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
        guard let sessionId = currentSessionId, purchaseContinuation != nil else { return }
        stopForegroundObserver()

        Task { [weak self] in
            guard let self else { return }
            do {
                let confirmation = try await confirmCheckoutSession(sessionId: sessionId)
                PendingCheckout.clear()
                // Dismiss SFSafariViewController if present
                await MainActor.run {
                    if let topVC = UIWindowHelper.findTopMostViewController(), topVC is SFSafariViewController {
                        topVC.dismiss(animated: true)
                    }
                }
                let txnId = confirmation.transactionId ?? sessionId
                let productId = currentProductId ?? confirmation.productId
                latestTransactionResult = HeliumTransactionIdResult(
                    productId: productId,
                    transactionId: txnId,
                    originalTransactionId: txnId
                )
                entitlementsSource?.didCompletePurchase(
                    heliumProductId: productId,
                    subscriptionExpiresAt: confirmation.expiresAt
                )
                resumePurchase(with: .purchased)
            } catch HeliumStripeAPIError.checkoutSessionNotCompleted {
                // Session not completed — user came back without paying
                PendingCheckout.clear()
                resumePurchase(with: .cancelled)
            } catch {
                // Network/server error — don't clear pending state, keep it for retry
                resumePurchase(with: .failed(error))
            }
        }
    }

    // MARK: - Pending Checkout Recovery (app terminated)

    /// Call on init to recover any checkout that was in progress when the app was terminated.
    public func resolvePendingCheckoutIfNeeded() {
        guard let pending = PendingCheckout.load() else { return }
        PendingCheckout.clear()

        guard !pending.isExpired else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let confirmation = try await confirmCheckoutSession(sessionId: pending.sessionId)
                let txnId = confirmation.transactionId ?? pending.sessionId
                let productId = confirmation.productId.isEmpty ? pending.productId : confirmation.productId
                latestTransactionResult = HeliumTransactionIdResult(
                    productId: productId,
                    transactionId: txnId,
                    originalTransactionId: txnId
                )
                entitlementsSource?.didCompletePurchase(
                    heliumProductId: pending.productId,
                    subscriptionExpiresAt: confirmation.expiresAt
                )
            } catch {
                // Session wasn't completed — nothing to recover
            }
        }
    }

    // MARK: - Checkout Completion

    private func completeCheckout(result: StripeCheckoutResult) {
        guard let productId = currentProductId else { return }
        let sessionId = currentSessionId ?? ""

        switch result {
        case .success(let returnedSessionId):
            let resolvedSessionId = returnedSessionId ?? sessionId
            Task { [weak self] in
                guard let self else { return }
                do {
                    let confirmation = try await confirmCheckoutSession(sessionId: resolvedSessionId)
                    let txnId = confirmation.transactionId ?? resolvedSessionId
                    latestTransactionResult = HeliumTransactionIdResult(
                        productId: confirmation.productId.isEmpty ? productId : confirmation.productId,
                        transactionId: txnId,
                        originalTransactionId: txnId
                    )
                    entitlementsSource?.didCompletePurchase(
                        heliumProductId: productId,
                        subscriptionExpiresAt: confirmation.expiresAt
                    )
                    resumePurchase(with: .purchased)
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
        currentProductId = nil
        currentSessionId = nil
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
        return (checkoutURL: url, sessionId: response.sessionId ?? "")
    }

    /// Confirms a completed Stripe Checkout Session and returns the purchase details.
    /// Throws if the session has not been completed yet.
    func confirmCheckoutSession(sessionId: String) async throws -> PaymentSuccessResponse {
        var body = HeliumStripeAPIClient.shared.baseRequestBody()
        body["sessionId"] = sessionId

        let response: ExecutePurchaseResponse = try await HeliumStripeAPIClient.shared.post("stripe/confirm-checkout", body: body)

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
        onReturnedToForeground()
    }
}

// MARK: - Error

enum StripeCheckoutError: LocalizedError {
    case cannotPresentCheckout
    case notInitialized

    var errorDescription: String? {
        switch self {
        case .cannotPresentCheckout:
            return "Could not present the checkout view"
        case .notInitialized:
            return "Stripe checkout is not initialized. Call initializeWithStripeOneTap() or configure StripeCheckoutManager first."
        }
    }
}
