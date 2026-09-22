import Foundation

enum SdkApiMethod: String, CaseIterable {
    case initialize
    case presentPaywall = "present_paywall"
    case hidePaywall = "hide_paywall"
    case hideAllPaywalls = "hide_all_paywalls"
    case canShowPaywallFor = "can_show_paywall_for"
    case getPaywallInfo = "get_paywall_info"
    case upsellViewForTrigger = "upsell_view_for_trigger"
    case resetHelium = "reset_helium"
    case addHeliumEventListener = "add_helium_event_listener"
    case removeHeliumEventListener = "remove_helium_event_listener"
    case removeAllHeliumEventListeners = "remove_all_helium_event_listeners"
    case handleDeepLink = "handle_deep_link"
    case handleURL = "handle_url"
    case createStripePortalSession = "create_stripe_portal_session"
    case createPaddlePortalSession = "create_paddle_portal_session"
    case getStripeCustomerId = "get_stripe_customer_id"
    case getPaddleCustomerId = "get_paddle_customer_id"
    case resetStripeEntitlements = "reset_stripe_entitlements"
    case resetPaddleEntitlements = "reset_paddle_entitlements"
    case enableExternalWebCheckout = "enable_external_web_checkout"
    case disableExternalWebCheckout = "disable_external_web_checkout"
    case identitySetUserId = "identity_set_user_id"
    case identitySetRevenueCatAppUserId = "identity_set_revenue_cat_app_user_id"
    case identitySetThirdPartyAnalyticsAnonymousId = "identity_set_third_party_analytics_anonymous_id"
    case identitySetAppAccountToken = "identity_set_app_account_token"
    case identitySetUserTraits = "identity_set_user_traits"
    case identityAddUserTraits = "identity_add_user_traits"
    case setWrapperSdkInfo = "set_wrapper_sdk_info"

    var wireName: String { "sdk_api_\(rawValue)_called" }

    var tags: Set<HeliumObservabilityTag> {
        var tags: Set<HeliumObservabilityTag> = [.sdkApi]
        switch self {
        case .initialize, .resetHelium, .addHeliumEventListener, .removeHeliumEventListener, .removeAllHeliumEventListeners:
            tags.insert(.lifecycle)
        case .presentPaywall, .hidePaywall, .hideAllPaywalls, .canShowPaywallFor, .getPaywallInfo:
            tags.insert(.presentation)
        case .upsellViewForTrigger, .handleDeepLink:
            tags.formUnion([.presentation, .deprecatedApi])
        case .handleURL, .createStripePortalSession, .createPaddlePortalSession, .getStripeCustomerId,
             .getPaddleCustomerId, .resetStripeEntitlements, .resetPaddleEntitlements:
            tags.insert(.webCheckout)
        case .enableExternalWebCheckout, .disableExternalWebCheckout:
            tags.formUnion([.webCheckout, .config])
        case .identitySetUserId, .identitySetRevenueCatAppUserId, .identitySetThirdPartyAnalyticsAnonymousId,
             .identitySetAppAccountToken, .identitySetUserTraits, .identityAddUserTraits:
            tags.insert(.identity)
        case .setWrapperSdkInfo:
            tags.insert(.config)
        }
        return tags
    }
}

enum SdkApiEntryPoint: String {
    case presentPaywall = "present_paywall"
    case swiftuiModifier = "swiftui_modifier"
    case embeddedView = "embedded_view"
    case deepLink = "deep_link"
}

struct SdkApiCalled: HeliumObservabilityEvent {
    let method: SdkApiMethod
    let apiCallIndex: Int
    let callCountForMethod: Int
    let calledBeforeInitialize: Bool
    let methodProperties: [String: Any]

    var name: String { method.wireName }
    var tags: Set<HeliumObservabilityTag> { method.tags }
    var properties: [String: Any] {
        var p = methodProperties
        p["apiCallIndex"] = apiCallIndex
        p["callCountForMethod"] = callCountForMethod
        p["calledBeforeInitialize"] = calledBeforeInitialize
        return p
    }
}

final class SdkApiCallTracker {
    static let shared = SdkApiCallTracker()

    struct Call {
        let apiCallIndex: Int
        let callCountForMethod: Int
    }

    private struct State {
        var apiCallIndex = 0
        var callCounts: [SdkApiMethod: Int] = [:]
        var initializeCount = 0
        var initializedAt: Date?
    }

    @HeliumAtomic private var state = State()

    func record(_ method: SdkApiMethod) -> Call {
        _state.withValue { state in
            state.apiCallIndex += 1
            let count = (state.callCounts[method] ?? 0) + 1
            state.callCounts[method] = count
            return Call(apiCallIndex: state.apiCallIndex, callCountForMethod: count)
        }
    }

    func markInitialized() {
        _state.withValue { state in
            state.initializeCount += 1
            state.initializedAt = Date()
        }
    }

    func markReset() {
        _state.withValue { $0.initializedAt = nil }
    }

    var initializeCount: Int { state.initializeCount }

    var msSinceInitialize: Int? {
        state.initializedAt.map(msSince)
    }

    static func shouldEmit(callCount: Int) -> Bool {
        callCount <= 20 || callCount.nonzeroBitCount == 1
    }
}

func trackSdkApiCall(
    _ method: SdkApiMethod,
    _ properties: [String: Any] = [:],
    scope: PaywallObservabilityScope? = nil,
    wasInitialized: Bool = Helium.shared.isInitialized()
) {
    let call = SdkApiCallTracker.shared.record(method)
    guard SdkApiCallTracker.shouldEmit(callCount: call.callCountForMethod) else { return }
    HeliumObservabilityManager.shared.track(
        SdkApiCalled(
            method: method,
            apiCallIndex: call.apiCallIndex,
            callCountForMethod: call.callCountForMethod,
            calledBeforeInitialize: !wasInitialized,
            methodProperties: properties
        ),
        scope: scope
    )
}
