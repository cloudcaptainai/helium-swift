import Foundation

func initializeObservabilityProperties(ignoredAlreadyInitialized: Bool) -> [String: Any] {
    let config = Helium.config
    let identity = HeliumIdentityManager.shared
    let testing = Helium.testing
    let initializeCount = SdkApiCallTracker.shared.initializeCount
    return [
        "ignoredAlreadyInitialized": ignoredAlreadyInitialized,
        "isReinitialize": initializeCount > 0,
        "initializeCount": initializeCount + (ignoredAlreadyInitialized ? 0 : 1),
        "purchaseDelegateType": config.purchaseDelegate.delegateType,
        "hasCustomApiEndpoint": config.customAPIEndpoint != nil,
        "hasCustomFallbacks": config.customFallbacksURL != nil,
        "defaultLoadingBudgetMs": Int(config.defaultLoadingBudget * 1000),
        "hasDefaultLoadingView": config.defaultLoadingView != nil,
        "lightDarkModeOverride": String(describing: config.lightDarkModeOverride),
        "hasThirdPartyEntitlementsSource": config.thirdPartyEntitlementsSource != nil,
        "paywallNotShownDiagnosticDisplayEnabled": config.paywallNotShownDiagnosticDisplayEnabled,
        "paywallPreviewsEnabledInDevBuilds": config.paywallPreviewsAutoEnabledInDevBuilds,
        "openPaywallLinksInApp": config.openPaywallLinksInApp,
        "webCheckoutProcessors": config.webCheckoutProcessors.observabilityValue,
        "allowWebCheckoutWithoutUserId": config.allowWebCheckoutWithoutUserId,
        "logLevel": String(describing: config.logLevel),
        "hasTestingHandlers": testing.purchaseHandler != nil || testing.restoreHandler != nil
            || testing.introOfferEligibility != nil || testing.promoOfferEligibility != nil,
        "hasUserId": identity.hasCustomUserId(),
        "hasRevenueCatAppUserId": identity.revenueCatAppUserId != nil,
        "hasThirdPartyAnalyticsAnonymousId": identity.getThirdPartyAnalyticsAnonymousId() != nil,
        "userTraitCount": identity.getUserTraits().count,
    ]
}

func presentPaywallObservabilityProperties(
    trigger: String,
    config: PaywallPresentationConfig,
    entryPoint: SdkApiEntryPoint,
    deprecatedOverload: Bool,
    hasEventHandlers: Bool,
    hasOnEntitled: Bool,
    hasOnPaywallNotShown: Bool,
    hasPaywallNotShownContent: Bool? = nil
) -> [String: Any] {
    var p = paywallLookupObservabilityProperties(trigger: trigger)
    p["entryPoint"] = entryPoint.rawValue
    p["deprecatedOverload"] = deprecatedOverload
    p["hasEventHandlers"] = hasEventHandlers
    p["hasOnEntitled"] = hasOnEntitled
    p["hasOnPaywallNotShown"] = hasOnPaywallNotShown
    if let hasPaywallNotShownContent { p["hasPaywallNotShownContent"] = hasPaywallNotShownContent }
    p.merge(config.observabilityProperties) { _, new in new }
    return p
}

func paywallLookupObservabilityProperties(trigger: String) -> [String: Any] {
    [
        "trigger": trigger,
        "isInitialized": Helium.shared.isInitialized(),
        "downloadStatus": HeliumFetchedConfigManager.shared.downloadStatus.rawValue,
    ]
}

func canShowPaywallObservabilityProperties(trigger: String, result: CanShowPaywallResult) -> [String: Any] {
    var p = paywallLookupObservabilityProperties(trigger: trigger)
    p["canShow"] = result.canShow
    if let isFallback = result.isFallback { p["isFallback"] = isFallback }
    if let reason = result.paywallUnavailableReason { p["paywallUnavailableReason"] = reason.rawValue }
    return p
}

func paywallInfoObservabilityProperties(trigger: String, info: PaywallInfo?) -> [String: Any] {
    var p = paywallLookupObservabilityProperties(trigger: trigger)
    p["found"] = info != nil
    if let info { p["shouldShow"] = info.shouldShow }
    return p
}

func userTraitsObservabilityProperties(_ traits: HeliumUserTraits, viaMap: Bool) -> [String: Any] {
    [
        "traitCount": traits.count,
        "traitKeys": keysForObservability(traits.keys),
        "viaMap": viaMap,
    ]
}

func webCheckoutObservabilityProperties(
    processors: WebCheckoutProcessors,
    hasRedirectUrl: Bool,
    accepted: Bool,
    deprecatedOverload: Bool
) -> [String: Any] {
    [
        "processors": processors.observabilityValue,
        "hasRedirectUrl": hasRedirectUrl,
        "accepted": accepted,
        "deprecatedOverload": deprecatedOverload,
    ]
}

extension PaywallPresentationConfig {
    var observabilityProperties: [String: Any] {
        var p: [String: Any] = [
            "hasPresentFromViewController": presentFromViewController != nil,
            "hasCustomPaywallTraits": customPaywallTraits != nil,
            "customPaywallTraitCount": customPaywallTraits?.count ?? 0,
            "dontShowIfAlreadyEntitled": dontShowIfAlreadyEntitled,
        ]
        if let customPaywallTraits { p["customPaywallTraitKeys"] = keysForObservability(customPaywallTraits.keys) }
        if let loadingBudget { p["loadingBudgetMs"] = Int(loadingBudget * 1000) }
        if let presentationStyle { p["presentationStyle"] = presentationStyle.rawValue }
        return p
    }
}

extension WebCheckoutProcessors {
    var observabilityValue: String {
        var names: [String] = []
        if contains(.paddle) { names.append("paddle") }
        if contains(.stripe) { names.append("stripe") }
        return names.joined(separator: ",")
    }
}

func resetHeliumObservabilityProperties(
    clearUserId: Bool,
    clearUserTraits: Bool,
    clearHeliumEventListeners: Bool,
    clearExperimentAllocations: Bool,
    clearCachedPaywalls: Bool,
    autoInitialize: Bool
) -> [String: Any] {
    [
        "wasInitialized": Helium.shared.isInitialized(),
        "clearUserId": clearUserId,
        "clearUserTraits": clearUserTraits,
        "clearHeliumEventListeners": clearHeliumEventListeners,
        "clearExperimentAllocations": clearExperimentAllocations,
        "clearCachedPaywalls": clearCachedPaywalls,
        "autoInitialize": autoInitialize,
    ]
}

func upsellViewObservabilityProperties(
    trigger: String,
    customPaywallTraits: HeliumUserTraits?,
    hasEventHandlers: Bool,
    returnedView: Bool
) -> [String: Any] {
    var p: [String: Any] = [
        "trigger": trigger,
        "hasCustomPaywallTraits": customPaywallTraits != nil,
        "customPaywallTraitCount": customPaywallTraits?.count ?? 0,
        "hasEventHandlers": hasEventHandlers,
        "returnedView": returnedView,
    ]
    if let customPaywallTraits { p["customPaywallTraitKeys"] = keysForObservability(customPaywallTraits.keys) }
    return p
}

func handleDeepLinkObservabilityProperties(url: URL?, handled: Bool) -> [String: Any] {
    [
        "hasUrl": url != nil,
        "isHeliumTestHost": url?.host == "helium-test",
        "handled": handled,
    ]
}

func handleURLObservabilityProperties(url: URL, webCheckoutEnabled: Bool, redirectKind: HeliumCheckoutRedirectType?) -> [String: Any] {
    var p: [String: Any] = [
        "webCheckoutEnabled": webCheckoutEnabled,
        "matched": redirectKind != nil,
    ]
    if let scheme = url.scheme { p["scheme"] = scheme }
    if let redirectKind { p["redirectKind"] = redirectKind.rawValue }
    return p
}

func restoreFailedStringsObservabilityProperties(customTitle: String?, customMessage: String?, customCloseButtonText: String?) -> [String: Any] {
    [
        "hasCustomTitle": customTitle != nil,
        "hasCustomMessage": customMessage != nil,
        "hasCustomCloseButtonText": customCloseButtonText != nil,
    ]
}
