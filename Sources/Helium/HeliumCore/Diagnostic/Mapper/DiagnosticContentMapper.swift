//
//  DiagnosticContentMapper.swift
//  Helium
//

import Foundation

/// Maps a paywall-not-shown reason onto the authored copy that describes it.
///
/// Two invariants hold across the whole matrix:
///  - **No URLs in prose.** `DiagnosticContent.cta` and `DiagnosticContent.usersWillSeeLink` own
///    every URL, so nothing downstream has to detect one inside `title`, `body` or `usersWillSee`.
///  - **No raw reason codes as prose.** An unrecognised code maps to generic copy and surfaces its
///    code only as `DiagnosticContent.reasonCode`.
///
/// One content record serves two contexts: the modal (nothing rendered) and the fallback-shown log
/// (a fallback rendered). The fields divide along that seam — `body` states the *cause*, which is
/// true in both contexts, while `usersWillSee` states what this user actually got and is rendered
/// only by the modal. That is what lets a row like `forceShowFallback` read correctly in a log line
/// saying a fallback was shown and in a modal that only appears when one wasn't.
///
/// Helium sells digital in-app products and subscriptions, so product copy names the store's
/// vocabulary (in-app products, subscriptions, the App Store) and never generic commerce language.
struct DiagnosticContentMapper {

    private enum Url {
        static let quickstart = "https://docs.tryhelium.com/sdk/quickstart-ios"
        static let entitlements = "\(quickstart)#checking-subscription-status-%26-entitlements"
        static let workflows = "https://app.tryhelium.com/workflows"
        static let paywalls = "https://app.tryhelium.com/paywalls"
        static let fallbackGuide = "https://docs.tryhelium.com/guides/fallback-bundle"
    }

    private enum UsersWillSee {
        /// Shared outcome for reasons a bundled fallback would have covered.
        static let seesNothingConsiderFallback =
            "Users hitting this trigger see nothing. Consider adding a fallback paywall."

        /// Outcome for failures that stop the SDK before any paywall — fallback included — can load.
        static let seesNothingNoFallbackPossible =
            "Users hitting this trigger see nothing — no paywall and no fallback can load until "
            + "this is fixed."

        /// Pairs with the outcomes above that advise a fallback: the prose gives the advice, this
        /// points at how to act on it.
        static let fallbackGuideLink = DiagnosticLink(
            label: "Read the fallback paywall guide",
            url: Url.fallbackGuide
        )
    }

    /// Stands in for the reason code when the SDK reported no reason at all.
    private static let unknownReasonCode = "unknown"

    // MARK: - Entry points

    /// Maps a skip — a paywall Helium deliberately chose not to show. Skip copy needs no runtime
    /// context beyond the reason itself.
    func mapSkip(_ reason: PaywallSkippedReason) -> DiagnosticContent {
        switch reason {
        case .targetingHoldout: return targetingHoldout()
        case .alreadyEntitled: return alreadyEntitled()
        }
    }

    /// Maps the reason a paywall was unavailable, whether or not a fallback then rendered.
    func mapUnavailable(_ reason: PaywallUnavailableReason?, context: DiagnosticContext) -> DiagnosticContent {
        guard let reason else { return unknown(Self.unknownReasonCode) }
        let code = reason.rawValue

        // Deliberately exhaustive with no `default:` — a new PaywallUnavailableReason case becomes a
        // compile error here rather than silently leaking its raw code into the UI.
        switch reason {
        case .notInitialized:
            return notInitialized(code)
        case .noRootController:
            return noRootController(code)
        case .triggerHasNoPaywall:
            return triggerHasNoPaywall(code, context)
        case .noProductsIOS:
            return noProducts(code, context)
        case .webCheckoutNoCustomUserId:
            return webCheckoutNoCustomUserId(code)
        case .webCheckoutNotEnabled:
            return webCheckoutNotEnabled(code, context)

        case .paywallsNotDownloaded, .configFetchInProgress, .bundlesFetchInProgress, .productsFetchInProgress:
            return paywallsNotDownloaded(code)
        case .paywallsDownloadFail:
            return paywallsDownloadFail(code)

        case .couldNotFindBundleUrl,
             .bundleFetchInvalidUrlDetected,
             .bundleFetchInvalidUrl,
             .bundleFetch403,
             .bundleFetch404,
             .bundleFetch410,
             .bundleFetchCannotDecodeContent:
            return bundleRetrieval(code)
        case .webviewRenderFail, .bridgingError:
            return renderFailure(code)
        case .secondTryNoMatch:
            return secondTryNoMatch(code, context)
        case .invalidResolvedConfig:
            return invalidResolvedConfig(code)

        case .alreadyPresented:
            return alreadyPresented(code)
        case .forceShowFallback:
            return forceShowFallback(code)
        }
    }

    // MARK: - EXPECTED

    private func targetingHoldout() -> DiagnosticContent {
        DiagnosticContent(
            category: .expected,
            title: "Paywall skipped",
            body: "Helium did not show this paywall due to your workflow's targeting configuration. "
                + "Check your workflow configuration if this is not expected.",
            usersWillSee: "Users matched by this targeting rule see no paywall and the app simply "
                + "continues. Other users see the paywall normally.",
            usersWillSeeLink: nil,
            cta: .openUrl(label: "Open Workflows", url: Url.workflows),
            reasonCode: PaywallSkippedReason.targetingHoldout.rawValue
        )
    }

    private func alreadyEntitled() -> DiagnosticContent {
        DiagnosticContent(
            category: .expected,
            title: "Already subscribed",
            body: "Paywall not shown because this user is already entitled to a product in this "
                + "paywall. To show paywalls to entitled users anyway, set dontShowIfAlreadyEntitled "
                + "to false.",
            usersWillSee: "Subscribed users see no paywall; users without the entitlement see it "
                + "normally.",
            usersWillSeeLink: nil,
            cta: .openUrl(label: "Entitlement Docs", url: Url.entitlements),
            reasonCode: PaywallSkippedReason.alreadyEntitled.rawValue
        )
    }

    /// Suppressed from the modal, so only `body` is ever surfaced — in the log.
    private func alreadyPresented(_ code: String) -> DiagnosticContent {
        DiagnosticContent(
            category: .expected,
            title: "A Helium paywall is already being presented",
            body: "Another Helium paywall is already on screen, so this request was ignored. "
                + "Dismiss the current paywall before presenting another.",
            usersWillSee: "Users see the paywall that is already on screen.",
            usersWillSeeLink: nil,
            cta: .openUrl(label: "View Docs", url: Url.quickstart),
            reasonCode: code
        )
    }

    private func forceShowFallback(_ code: String) -> DiagnosticContent {
        DiagnosticContent(
            category: .expected,
            title: "Fallback paywall forced for this trigger",
            body: "This trigger's paywall is configured to force the bundled fallback, so Helium "
                + "attempted your fallback instead of the remote paywall.",
            // The modal only appears when nothing rendered, so reaching it means the forced fallback
            // itself failed. The log path, where the fallback did render, never reads this field.
            usersWillSee: "The bundled fallback could not be rendered, so this user saw nothing.",
            usersWillSeeLink: nil,
            cta: .openUrl(label: "View Docs", url: Url.quickstart),
            reasonCode: code
        )
    }

    // MARK: - SETUP

    private func notInitialized(_ code: String) -> DiagnosticContent {
        DiagnosticContent(
            category: .setup,
            title: "Helium isn't initialized",
            body: "Helium.shared.initialize(apiKey:) was never called. Initialize Helium at app "
                + "launch, before any trigger can fire.",
            usersWillSee: UsersWillSee.seesNothingNoFallbackPossible,
            usersWillSeeLink: nil,
            cta: .openUrl(label: "View Setup Docs", url: Url.quickstart),
            reasonCode: code
        )
    }

    private func noRootController(_ code: String) -> DiagnosticContent {
        DiagnosticContent(
            category: .setup,
            title: "No screen to present the paywall on",
            body: "Helium could not find a root view controller to present from. Trigger the paywall "
                + "after your window and root view controller exist — not during app or scene startup.",
            usersWillSee: UsersWillSee.seesNothingNoFallbackPossible,
            usersWillSeeLink: nil,
            cta: .openUrl(label: "View Setup Docs", url: Url.quickstart),
            reasonCode: code
        )
    }

    private func triggerHasNoPaywall(_ code: String, _ context: DiagnosticContext) -> DiagnosticContent {
        DiagnosticContent(
            category: .setup,
            title: "No paywall is connected to this trigger",
            body: "Could not find a paywall for the trigger \"\(context.trigger)\". Verify the trigger "
                + "is in a workflow. Changes to a workflow can take a few minutes to be reflected here.",
            usersWillSee: UsersWillSee.seesNothingConsiderFallback,
            usersWillSeeLink: UsersWillSee.fallbackGuideLink,
            cta: .openUrl(label: "Open Workflows", url: Url.workflows),
            reasonCode: code
        )
    }

    private func noProducts(_ code: String, _ context: DiagnosticContext) -> DiagnosticContent {
        DiagnosticContent(
            category: .setup,
            title: "This paywall has no iOS products",
            body: "The paywall for \"\(context.trigger)\" does not include any iOS products. Sync your "
                + "App Store in-app products and subscriptions, then select them on this paywall.",
            usersWillSee: UsersWillSee.seesNothingConsiderFallback,
            usersWillSeeLink: UsersWillSee.fallbackGuideLink,
            cta: .openUrl(label: "Open Paywall Editor", url: paywallEditorUrl(context)),
            reasonCode: code
        )
    }

    private func webCheckoutNoCustomUserId(_ code: String) -> DiagnosticContent {
        DiagnosticContent(
            category: .setup,
            title: "Web checkout needs a custom user ID",
            body: "External web checkout requires a custom user ID so purchases can be linked to this "
                + "user. Set one via Helium.identify.userId before showing the paywall.",
            usersWillSee: UsersWillSee.seesNothingConsiderFallback,
            usersWillSeeLink: UsersWillSee.fallbackGuideLink,
            cta: .openUrl(label: "View Docs", url: Url.quickstart),
            reasonCode: code
        )
    }

    private func webCheckoutNotEnabled(_ code: String, _ context: DiagnosticContext) -> DiagnosticContent {
        var body = "This paywall has Stripe/Paddle products, but external web checkout is not enabled "
            + "for those processors. Call Helium.config.enableExternalWebCheckout(...) to enable."
        if !context.webCheckoutProcessors.isEmpty {
            body += " Currently enabled: \(context.webCheckoutProcessors)."
        }
        return DiagnosticContent(
            category: .setup,
            title: "Web checkout isn't enabled",
            body: body,
            usersWillSee: UsersWillSee.seesNothingConsiderFallback,
            usersWillSeeLink: UsersWillSee.fallbackGuideLink,
            cta: .openUrl(label: "View Docs", url: Url.quickstart),
            reasonCode: code
        )
    }

    // MARK: - NETWORK

    private func paywallsNotDownloaded(_ code: String) -> DiagnosticContent {
        DiagnosticContent(
            category: .network,
            title: "Paywalls are still downloading",
            body: "Paywalls had not completed downloading when this trigger fired. Check your "
                + "connection, and consider raising the loading budget or initializing Helium sooner.",
            usersWillSee: "Real users see a loading indication followed by no paywall. Consider "
                + "adding a fallback paywall.",
            usersWillSeeLink: UsersWillSee.fallbackGuideLink,
            cta: .openUrl(label: "View Docs", url: Url.quickstart),
            reasonCode: code
        )
    }

    private func paywallsDownloadFail(_ code: String) -> DiagnosticContent {
        DiagnosticContent(
            category: .network,
            title: "Paywalls failed to download",
            body: "Paywalls failed to download. Check this device's connection and your Helium API key.",
            usersWillSee: UsersWillSee.seesNothingConsiderFallback,
            usersWillSeeLink: UsersWillSee.fallbackGuideLink,
            cta: .openUrl(label: "View Docs", url: Url.quickstart),
            reasonCode: code
        )
    }

    // MARK: - INTEGRATION ERROR

    private func bundleRetrieval(_ code: String) -> DiagnosticContent {
        DiagnosticContent(
            category: .integrationError,
            title: "The paywall couldn't be retrieved",
            body: "Helium could not fetch or read this paywall's bundle. Copy the diagnostic report "
                + "and contact Helium if this continues to be an issue.",
            usersWillSee: UsersWillSee.seesNothingConsiderFallback,
            usersWillSeeLink: UsersWillSee.fallbackGuideLink,
            cta: .copyReport,
            reasonCode: code
        )
    }

    private func renderFailure(_ code: String) -> DiagnosticContent {
        DiagnosticContent(
            category: .integrationError,
            title: "The paywall failed to render",
            body: "The paywall's web view failed to render, or could not communicate with the SDK. "
                + "Retry once; if it reproduces, copy the diagnostic report and contact Helium.",
            usersWillSee: UsersWillSee.seesNothingConsiderFallback,
            usersWillSeeLink: UsersWillSee.fallbackGuideLink,
            cta: .copyReport,
            reasonCode: code
        )
    }

    /// Fires when a presented paywall asks Helium to open a second try paywall and neither the
    /// requested paywall uuid nor the `<trigger>_second_try` trigger resolves. The context trigger
    /// is the second-try trigger, not the paywall the user is looking at.
    private func secondTryNoMatch(_ code: String, _ context: DiagnosticContext) -> DiagnosticContent {
        DiagnosticContent(
            category: .integrationError,
            title: "No second try paywall found",
            body: "This paywall asked Helium to open a second try paywall, but no paywall matched "
                + "\"\(context.trigger)\". Confirm the second try paywall exists and is connected.",
            usersWillSee: "Users who reach this step see no second try paywall — the paywall they are "
                + "on stays on screen.",
            usersWillSeeLink: nil,
            cta: .openUrl(label: "Open Paywall Editor", url: paywallEditorUrl(context)),
            reasonCode: code
        )
    }

    private func invalidResolvedConfig(_ code: String) -> DiagnosticContent {
        DiagnosticContent(
            category: .integrationError,
            title: "Paywall configuration is invalid",
            body: "The resolved configuration for this trigger failed validation. Copy the diagnostic "
                + "report and contact Helium support.",
            usersWillSee: UsersWillSee.seesNothingConsiderFallback,
            usersWillSeeLink: UsersWillSee.fallbackGuideLink,
            cta: .copyReport,
            reasonCode: code
        )
    }

    private func unknown(_ code: String) -> DiagnosticContent {
        DiagnosticContent(
            category: .integrationError,
            title: "The paywall couldn't be shown",
            body: "Helium hit an unexpected state. Copy the diagnostic report and contact Helium support.",
            usersWillSee: UsersWillSee.seesNothingConsiderFallback,
            usersWillSeeLink: UsersWillSee.fallbackGuideLink,
            cta: .copyReport,
            reasonCode: code
        )
    }

    // MARK: - URLs

    /// Deep-links straight to the offending paywall when the id resolved; otherwise the editor's
    /// paywall list, which is still the right place to go.
    private func paywallEditorUrl(_ context: DiagnosticContext) -> String {
        guard let paywallId = context.paywallId else { return Url.paywalls }
        return "\(Url.paywalls)/\(paywallId)"
    }
}
