import Foundation

/// Event for the observability pipeline. Per-event payload only — common
/// props (identity, paywall scope, platform) are attached by the manager.
protocol HeliumObservabilityEvent {
    var name: String { get }
    var properties: [String: Any] { get }
}

/// Truncates strings before they hit the wire so a stack-trace-heavy error
/// can't blow up payload size on a per-event basis.
func truncatedForObservability(_ s: String?, maxLength: Int = 500) -> String? {
    guard let s, s.count > maxLength else { return s }
    return String(s.prefix(maxLength)) + "…(truncated)"
}

func msSince(_ start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

func decomposeError(_ error: Error) -> (httpStatus: Int?, errorClass: String, errorMessage: String?) {
    if let bff = error as? PaddleBFFError {
        switch bff {
        case .requestFailed(let statusCode, let rawBody):
            return (statusCode, "PaddleBFFError.requestFailed", rawBody)
        }
    }
    if let apiErr = error as? HeliumPaymentAPIError {
        switch apiErr {
        case .serverError(let statusCode, let message):
            return (statusCode, "HeliumPaymentAPIError.serverError", message)
        case .invalidEndpoint(let path):
            return (nil, "HeliumPaymentAPIError.invalidEndpoint", path)
        case .checkoutSessionNotCompleted:
            return (nil, "HeliumPaymentAPIError.checkoutSessionNotCompleted", nil)
        case .notInitialized:
            return (nil, "HeliumPaymentAPIError.notInitialized", nil)
        }
    }
    if let webErr = error as? WebCheckoutError {
        return (nil, "WebCheckoutError.\(webErr.caseName)", webErr.errorDescription)
    }
    let className = String(describing: type(of: error))
    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    return (nil, className, message)
}

/// Shared shape for any outbound API call we instrument.
struct EndpointCallTelemetry {
    let durationMs: Int
    let success: Bool
    let httpStatus: Int?
    let errorClass: String?
    let errorMessage: String?

    init(
        durationMs: Int,
        success: Bool,
        httpStatus: Int? = nil,
        errorClass: String? = nil,
        errorMessage: String? = nil
    ) {
        self.durationMs = durationMs
        self.success = success
        self.httpStatus = httpStatus
        self.errorClass = errorClass
        self.errorMessage = truncatedForObservability(errorMessage)
    }

    var properties: [String: Any] {
        var p: [String: Any] = [
            "durationMs": durationMs,
            "success": success,
        ]
        if let httpStatus { p["httpStatus"] = httpStatus }
        if let errorClass { p["errorClass"] = errorClass }
        if let errorMessage { p["errorMessage"] = errorMessage }
        return p
    }
}

// MARK: - Paddle prefetch

struct PaddlePrefetchStarted: HeliumObservabilityEvent {
    let priceIds: [String]
    var name: String { "paddle_prefetch_started" }
    var properties: [String: Any] {
        ["priceIds": priceIds, "priceCount": priceIds.count]
    }
}

struct PaddlePrefetchBanditCompleted: HeliumObservabilityEvent {
    let priceId: String
    let discountId: String?
    let endpointCall: EndpointCallTelemetry
    let alreadyEntitledCode: String?

    var name: String { "paddle_prefetch_bandit_completed" }
    var properties: [String: Any] {
        var p = endpointCall.properties
        p["priceId"] = priceId
        if let discountId { p["discountId"] = discountId }
        if let alreadyEntitledCode { p["alreadyEntitledCode"] = alreadyEntitledCode }
        return p
    }
}

struct PaddlePrefetchBffCompleted: HeliumObservabilityEvent {
    let priceId: String
    let transactionId: String?
    let endpointCall: EndpointCallTelemetry

    var name: String { "paddle_prefetch_bff_completed" }
    var properties: [String: Any] {
        var p = endpointCall.properties
        p["priceId"] = priceId
        if let transactionId { p["transactionId"] = transactionId }
        return p
    }
}

enum PaddlePrefetchOutcomeKind: String {
    case ready, alreadyEntitled, caBlocked, failed
}

struct PaddlePrefetchOutcomeFinalized: HeliumObservabilityEvent {
    let priceId: String
    let outcome: PaddlePrefetchOutcomeKind
    let errorClass: String?
    let totalDurationMs: Int
    let ipGeoCountry: String?
    let ipGeoRegion: String?
    let ipGeoPostal: String?

    var name: String { "paddle_prefetch_outcome_finalized" }
    var properties: [String: Any] {
        var p: [String: Any] = [
            "priceId": priceId,
            "outcome": outcome.rawValue,
            "totalDurationMs": totalDurationMs,
        ]
        if let errorClass { p["errorClass"] = errorClass }
        if let ipGeoCountry { p["ipGeoCountry"] = ipGeoCountry }
        if let ipGeoRegion { p["ipGeoRegion"] = ipGeoRegion }
        if let ipGeoPostal { p["ipGeoPostal"] = ipGeoPostal }
        return p
    }
}

struct PaddlePrefetchAwaitResolved: HeliumObservabilityEvent {
    let tappedPriceId: String
    let awaitDurationMs: Int
    let readyCount: Int
    let alreadyEntitledCount: Int
    let failedCount: Int
    let caBlockedCount: Int
    let timedOutCount: Int
    let notStartedCount: Int
    let shortCircuited: Bool

    var name: String { "paddle_prefetch_await_resolved" }
    var properties: [String: Any] {
        [
            "tappedPriceId": tappedPriceId,
            "awaitDurationMs": awaitDurationMs,
            "readyCount": readyCount,
            "alreadyEntitledCount": alreadyEntitledCount,
            "failedCount": failedCount,
            "caBlockedCount": caBlockedCount,
            "timedOutCount": timedOutCount,
            "notStartedCount": notStartedCount,
            "shortCircuited": shortCircuited,
        ]
    }
}

// MARK: - Web checkout flow

enum WebCheckoutFlowOutcomeKind: String {
    case opened, preCheckResolved, error
}

struct WebCheckoutFlowStarted: HeliumObservabilityEvent {
    let provider: String
    let productKey: String

    var name: String { "web_checkout_flow_started" }
    var properties: [String: Any] {
        ["provider": provider, "productKey": productKey]
    }
}

struct WebCheckoutFlowResolved: HeliumObservabilityEvent {
    let provider: String
    let productKey: String
    let outcome: WebCheckoutFlowOutcomeKind
    let errorClass: String?
    let errorMessage: String?
    let totalDurationMs: Int

    var name: String { "web_checkout_flow_resolved" }
    var properties: [String: Any] {
        var p: [String: Any] = [
            "provider": provider,
            "productKey": productKey,
            "outcome": outcome.rawValue,
            "totalDurationMs": totalDurationMs,
        ]
        if let errorClass { p["errorClass"] = errorClass }
        if let msg = truncatedForObservability(errorMessage) { p["errorMessage"] = msg }
        return p
    }
}

struct WebCheckoutBrowserOpenAttempted: HeliumObservabilityEvent {
    let provider: String
    let success: Bool

    var name: String { "web_checkout_browser_open_attempted" }
    var properties: [String: Any] {
        ["provider": provider, "success": success]
    }
}

struct WebCheckoutRedirectReceived: HeliumObservabilityEvent {
    let provider: String
    let redirectKind: String
    let msSinceOpen: Int?
    let observationCount: Int

    var name: String { "web_checkout_redirect_received" }
    var properties: [String: Any] {
        var p: [String: Any] = [
            "provider": provider,
            "redirectKind": redirectKind,
            "observationCount": observationCount,
        ]
        if let msSinceOpen { p["msSinceOpen"] = msSinceOpen }
        return p
    }
}

enum WebCheckoutPurchaseDetectionSource: String {
    case foregroundObserver, successRedirect
}

struct WebCheckoutPurchaseDetected: HeliumObservabilityEvent {
    let provider: String
    let productId: String
    let source: WebCheckoutPurchaseDetectionSource
    let retryAttempt: Int
    let msSinceOpen: Int?
    let wasRestore: Bool

    var name: String { "web_checkout_purchase_detected" }
    var properties: [String: Any] {
        var p: [String: Any] = [
            "provider": provider,
            "productId": productId,
            "source": source.rawValue,
            "retryAttempt": retryAttempt,
            "wasRestore": wasRestore,
        ]
        if let msSinceOpen { p["msSinceOpen"] = msSinceOpen }
        return p
    }
}

struct WebCheckoutPurchaseCheckExhausted: HeliumObservabilityEvent {
    let provider: String
    let retries: Int
    let msSinceOpen: Int?
    let fromSuccessRedirect: Bool

    var name: String { "web_checkout_purchase_check_exhausted" }
    var properties: [String: Any] {
        var p: [String: Any] = [
            "provider": provider,
            "retries": retries,
            "fromSuccessRedirect": fromSuccessRedirect,
        ]
        if let msSinceOpen { p["msSinceOpen"] = msSinceOpen }
        return p
    }
}
