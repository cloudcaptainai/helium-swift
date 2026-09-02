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

/// Cuts a URL at its query/fragment, which can carry user data.
func urlForObservability(_ url: URL) -> String {
    String(url.absoluteString.prefix { $0 != "?" && $0 != "#" })
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
    let californiaDetected: Bool?
    let caConsentModalEnabled: Bool?
    // "true"/"false" as Paddle sent it, or nil when Paddle omitted the field.
    let consentRequired: String?

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
        if let californiaDetected { p["californiaDetected"] = californiaDetected }
        if let caConsentModalEnabled { p["caConsentModalEnabled"] = caConsentModalEnabled }
        if let consentRequired { p["consentRequired"] = consentRequired }
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

/// How a paywall link was requested: the paywall's explicit navigate action, or a tapped
/// HTML anchor. Only navigate links may open in-app.
enum PaywallLinkSource: String {
    case navigate, anchor
}

/// A link in paywall content was handed off to an in-app browser
/// (`SFSafariViewController`) or an external app — in-app when the source is navigate,
/// `openPaywallLinksInApp` is enabled, and the URL is a web URL; external otherwise
/// (including non-web schemes like `mailto:` and `tel:`). The reported URL is
/// cut at its query/fragment, which can carry user data.
struct PaywallLinkOpenAttempted: HeliumObservabilityEvent {
    let source: PaywallLinkSource
    let openedInApp: Bool
    let success: Bool
    let scheme: String?
    let url: String?

    var name: String { "paywall_link_open_attempted" }
    var properties: [String: Any] {
        var p: [String: Any] = ["source": source.rawValue, "openedInApp": openedInApp, "success": success]
        if let scheme { p["scheme"] = scheme }
        if let url { p["url"] = url }
        return p
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

// MARK: - Paywall webview render

enum PaywallJSErrorOutcome: String {
    /// Screen confirmed blank; routed into the load ladder.
    case fatalBlankScreen
    /// Content was visible, or the error came too late to act on.
    case benign
    /// Probe failed; treated as content so a working paywall is never replaced.
    case probeInconclusive
    /// The probe was abandoned mid-flight — the load attempt changed underneath it.
    case abandoned
}

/// An uncaught error or unhandled rejection in a paywall bundle. Emitted for
/// every report so broken bundles are queryable even when nothing went blank.
struct PaywallJSErrorDetected: HeliumObservabilityEvent {
    let source: String
    let errorMessage: String?
    let errorStack: String?
    let loadAttempt: String
    let outcome: PaywallJSErrorOutcome
    let msSinceLoadStart: Int?

    var name: String { "paywall_js_error_detected" }
    var properties: [String: Any] {
        var p: [String: Any] = [
            "source": source,
            "loadAttempt": loadAttempt,
            "outcome": outcome.rawValue,
        ]
        if let m = truncatedForObservability(errorMessage) { p["errorMessage"] = m }
        if let s = truncatedForObservability(errorStack, maxLength: 1000) { p["errorStack"] = s }
        if let msSinceLoadStart { p["msSinceLoadStart"] = msSinceLoadStart }
        return p
    }
}

struct PaywallWebProcessTerminated: HeliumObservabilityEvent {
    let loadAttempt: String
    let wasContentLoaded: Bool

    var name: String { "paywall_web_process_terminated" }
    var properties: [String: Any] {
        ["loadAttempt": loadAttempt, "wasContentLoaded": wasContentLoaded]
    }
}

/// The paywall webview freezes the fully assembled traits at display time, and that
/// always runs before a purchase can be triggered. A miss at purchase time therefore
/// means that invariant broke, so the traits get reconstructed as a safety net (some
/// traits over none) and this event flags the defect for investigation.
struct PaywallTraitsFreezeMissingAtMakePurchase: HeliumObservabilityEvent {
    let productId: String

    var name: String { "paywall_traits_freeze_missing_at_make_purchase" }
    var properties: [String: Any] {
        ["productId": productId]
    }
}

/// Reports the fallback bundle an app ships. The event's presence in the stream is
/// itself the "this app has fallbacks configured" signal, so it is only emitted when
/// a bundle was found and parsed.
///
/// A trigger maps to nil when it has no resolved paywall. Such triggers count toward
/// `triggerCount` but are absent from `triggerPaywallUUIDs`, so the two can disagree.
struct FallbackPaywallsConfigured: HeliumObservabilityEvent {
    let generatedAt: String?
    let organizationID: String?
    let triggerToPaywallUUID: [String: String?]

    var name: String { "fallback_paywalls_configured" }
    var properties: [String: Any] {
        let resolvedUUIDs = triggerToPaywallUUID.compactMapValues { $0 }
        var p: [String: Any] = [
            "triggerCount": triggerToPaywallUUID.count,
            "triggerPaywallUUIDs": resolvedUUIDs,
        ]
        if let generatedAt { p["generatedAt"] = generatedAt }
        if let organizationID { p["organizationId"] = organizationID }
        // Surfaced separately so consumers don't need to know the per-platform
        // default trigger name; the enriched `platform` property disambiguates.
        if let defaultUUID = resolvedUUIDs[HeliumFallbackViewManager.defaultFallbackTrigger] {
            p["defaultPaywallUUID"] = defaultUUID
        }
        return p
    }
}
