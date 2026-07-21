import Foundation

/// The single source of truth for what a developer is told when a paywall is unavailable. The same
/// copy reaches the log line and the body of the debug diagnostic view, so the two cannot drift.
enum PaywallDiagnosticMessages {

    static func remediationMessage(
        for reason: PaywallUnavailableReason?,
        trigger: String
    ) -> String {
        switch reason {
        case .notInitialized:
            return "Helium is not initialized"
        case .triggerHasNoPaywall:
            return "Could not find paywall for trigger \"\(trigger)\". Verify your trigger is in a workflow. Note that changes to a workflow may take a few minutes to be reflected here. https://app.tryhelium.com/workflows"
        case .paywallsNotDownloaded, .configFetchInProgress, .bundlesFetchInProgress, .productsFetchInProgress:
            return "Paywalls have not completed downloading. Check your connection and consider adjusting loading budget or initializing Helium sooner before presenting paywall"
        case .paywallsDownloadFail:
            return "Paywalls failed to download. Check your connection and Helium API key"
        case .alreadyPresented:
            return "A Helium paywall is already being presented"
        case .noProductsIOS:
            var paywallLink = "https://app.tryhelium.com/paywalls"
            let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)
            if let paywallId = paywallInfo?.paywallUUID {
                paywallLink += "/\(paywallId)"
            }
            return "Your paywall does not include any iOS products. Ensure you have synced your iOS products and selected products for your paywall \(paywallLink)"
        case .webCheckoutNoCustomUserId:
            return "External Web Checkout requires a custom user ID to be set"
        case .webCheckoutNotEnabled:
            return "External Web Checkout is not enabled for a payment processor this paywall requires. See Helium.config.enableExternalWebCheckout. Enabled processors: \(Helium.config.webCheckoutProcessors)"
        case .bundleFetchCannotDecodeContent:
            return "Paywall html could not be read. Ensure the paywall is not corrupted and contact Helium if this continues to be an issue."
        case .bundleFetchInvalidUrl, .bundleFetchInvalidUrlDetected, .bundleFetch403, .bundleFetch404, .bundleFetch410:
            return "Could not retrieve paywall. Contact Helium if this continues to be an issue."
        case .couldNotFindBundleUrl:
            return "Could not extract paywall url. Contact Helium if this continues to be an issue."
        default:
            return reason?.rawValue ?? ""
        }
    }
}
