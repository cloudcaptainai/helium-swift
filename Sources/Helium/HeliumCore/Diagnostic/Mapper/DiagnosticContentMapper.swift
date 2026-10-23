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
/// One content record serves every surface: the modal, the log line, and the support report. The
/// fields divide along one seam. `body` states the *cause*, which is true whether or not a fallback
/// then rendered, while `usersWillSee` states the outcome for a user who got nothing. Only the modal
/// renders the outcome, and it omits it when a fallback paywall is on screen behind it, so the cause
/// copy is the only part that has to hold in every context.
///
/// Helium sells digital in-app products and subscriptions, so product copy names the store's
/// vocabulary (in-app products, subscriptions, the App Store) and never generic commerce language.
struct DiagnosticContentMapper {

    private enum Url {
        static let quickstart = "https://docs.tryhelium.com/sdk/quickstart-ios"
        static let entitlements = "\(quickstart)#checking-subscription-status-%26-entitlements"
        static let workflows = "https://app.tryhelium.com/workflows"
        static let paywalls = "https://app.tryhelium.com/paywalls"
        static let profile = "https://app.tryhelium.com/profile"
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

    /// Maps a skip — a paywall Helium deliberately chose not to show. The already-entitled skip
    /// names the entitlements that caused it when they could be resolved.
    func mapSkip(
        _ reason: PaywallSkippedReason,
        entitledProducts: [EntitledProductDetail] = [],
        otherEntitlements: [EntitledProductDetail] = []
    ) -> DiagnosticContent {
        switch reason {
        case .targetingHoldout: return targetingHoldout()
        case .alreadyEntitled: return alreadyEntitled(entitledProducts, otherEntitlements)
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

        case .paywallsNotDownloaded:
            return paywallsNotDownloaded(code)
        case .configFetchInProgress:
            return configFetchInProgress(code)
        case .bundlesFetchInProgress:
            return bundlesFetchInProgress(code)
        case .productsFetchInProgress:
            return productsFetchInProgress(code)
        case .paywallsDownloadFail:
            return paywallsDownloadFail(code, context)

        case .couldNotFindBundleUrl:
            return bundleUrlMissing(code, context)
        case .bundleFetchInvalidUrlDetected, .bundleFetchInvalidUrl:
            return bundleUrlMalformed(code, context)
        case .bundleFetch403:
            return bundleFetchForbidden(code, context)
        case .bundleFetch404:
            return bundleFetchNotFound(code, context)
        case .bundleFetch410:
            return bundleFetchGone(code, context)
        case .bundleFetchCannotDecodeContent:
            return bundleFetchUnreadable(code, context)
        case .webviewRenderFail, .bridgingError:
            return renderFailure(code)
        case .secondTryNoMatch:
            return secondTryNoMatch(code, context)
        case .invalidResolvedConfig:
            return invalidResolvedConfig(code)

        case .alreadyPresented:
            return alreadyPresented(code)
        case .forceShowFallback:
            return context.trigger == HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER
                ? fallbackPreview(code)
                : forceShowFallback(code)
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

    private func alreadyEntitled(
        _ entitledProducts: [EntitledProductDetail],
        _ otherEntitlements: [EntitledProductDetail]
    ) -> DiagnosticContent {
        var body = "Paywall not shown because this user is already entitled to a product in this "
            + "paywall. To show paywalls to entitled users anyway, set dontShowIfAlreadyEntitled "
            + "to false."
        if !entitledProducts.isEmpty {
            let descriptions = entitledProducts.map(Self.describe)
            body += " This user is entitled to: \(descriptions.joined(separator: "; "))."
        }
        if !otherEntitlements.isEmpty {
            let descriptions = otherEntitlements.map(Self.describe)
            body += " Also entitled to: \(descriptions.joined(separator: "; "))."
        }
        return DiagnosticContent(
            category: .expected,
            title: "Already subscribed",
            body: body,
            usersWillSee: "Subscribed users see no paywall; users without the entitlement see it "
                + "normally.",
            usersWillSeeLink: nil,
            cta: .openUrl(label: "Entitlement Docs", url: Url.entitlements),
            reasonCode: PaywallSkippedReason.alreadyEntitled.rawValue
        )
    }

    private static let expirationDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static func describe(_ product: EntitledProductDetail) -> String {
        var qualifiers = [product.source.rawValue]
        if let expirationDate = product.expirationDate {
            qualifiers.append("expires \(expirationDateFormatter.string(from: expirationDate))")
        }
        return "\(product.heliumProductKey) (\(qualifiers.joined(separator: ", ")))"
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
            // The outcome renders only when nothing was shown, so reaching a user means the forced
            // fallback itself failed to render.
            usersWillSee: "The bundled fallback could not be rendered, so this user saw nothing.",
            usersWillSeeLink: nil,
            cta: .openUrl(label: "View Docs", url: Url.quickstart),
            reasonCode: code
        )
    }

    /// forceShowFallback on the preview trigger means the developer asked the control panel to
    /// render the bundled fallback, so the copy describes the preview rather than any trigger
    /// configuration.
    private func fallbackPreview(_ code: String) -> DiagnosticContent {
        DiagnosticContent(
            category: .expected,
            title: "Previewing your fallback paywall",
            body: "You asked the control panel to render the fallback paywall bundled with your "
                + "app instead of fetching a remote one. Nothing about your live paywalls or "
                + "triggers changed.",
            // The outcome renders only when nothing was shown, so it describes a preview whose
            // fallback failed to render.
            usersWillSee: "The bundled fallback could not be rendered, so this preview showed "
                + "nothing. Real users would hit the same failure whenever Helium needs this "
                + "fallback.",
            usersWillSeeLink: nil,
            cta: .openUrl(label: "Fallback Docs", url: Url.fallbackGuide),
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
        if let banditReason = context.banditReason {
            return DiagnosticContent(
                category: .setup,
                title: "No paywall was resolved for this trigger",
                body: banditReason,
                usersWillSee: "This user sees no paywall. Other users may receive one depending on "
                    + "targeting and eligibility. Consider adding a fallback paywall.",
                usersWillSeeLink: UsersWillSee.fallbackGuideLink,
                cta: .openUrl(label: "Open Workflows", url: Url.workflows),
                reasonCode: code
            )
        }

        return DiagnosticContent(
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
        stillLoading(
            code,
            title: "Paywalls haven't started downloading",
            body: "The paywall download had not started when this trigger fired. Initialize Helium "
                + "sooner, or raise the loading budget so the paywall has time to arrive."
        )
    }

    private func configFetchInProgress(_ code: String) -> DiagnosticContent {
        stillLoading(
            code,
            title: "Paywall configuration is still downloading",
            body: "Helium was still fetching your paywall configuration when this trigger fired. "
                + "Check this device's connection, and consider raising the loading budget or "
                + "initializing Helium sooner."
        )
    }

    private func bundlesFetchInProgress(_ code: String) -> DiagnosticContent {
        stillLoading(
            code,
            title: "Paywall content is still downloading",
            body: "Your paywall configuration arrived, but this paywall's content was still "
                + "downloading when this trigger fired. Check this device's connection, and consider "
                + "raising the loading budget."
        )
    }

    private func productsFetchInProgress(_ code: String) -> DiagnosticContent {
        stillLoading(
            code,
            title: "App Store products are still loading",
            body: "Your paywall configuration and content arrived, but Helium was still loading this "
                + "paywall's App Store in-app products and subscriptions when this trigger fired. "
                + "Consider raising the loading budget."
        )
    }

    private func stillLoading(_ code: String, title: String, body: String) -> DiagnosticContent {
        DiagnosticContent(
            category: .network,
            title: title,
            body: body,
            usersWillSee: "Real users see a loading indication followed by no paywall. Consider "
                + "adding a fallback paywall.",
            usersWillSeeLink: UsersWillSee.fallbackGuideLink,
            cta: .openUrl(label: "View Docs", url: Url.quickstart),
            reasonCode: code
        )
    }

    private func paywallsDownloadFail(_ code: String, _ context: DiagnosticContext) -> DiagnosticContent {
        switch context.fetchFailure {
        case .invalidApiKey:
            return downloadFailure(
                code,
                category: .setup,
                title: "Your Helium API key was rejected",
                body: "Helium rejected the API key passed to Helium.shared.initialize(apiKey:), so no "
                    + "paywalls could download. Copy the key from your Helium profile and pass it "
                    + "unchanged.",
                cta: .openUrl(label: "Open Profile", url: Url.profile)
            )
        case .configFetch:
            return downloadFailure(
                code,
                category: .network,
                title: "Paywall configuration failed to download",
                body: "Helium could not download your paywall configuration after several attempts. "
                    + "Check this device's connection and that nothing on this network blocks "
                    + "requests to Helium.",
                cta: .openUrl(label: "View Docs", url: Url.quickstart)
            )
        case .bundleFetch:
            return downloadFailure(
                code,
                category: .network,
                title: "Paywall content failed to download",
                body: "Your paywall configuration arrived, but at least one paywall's content could not "
                    + "be downloaded. Check this device's connection; if it keeps happening, copy the "
                    + "diagnostic report and contact Helium.",
                cta: .copyReport
            )
        case nil:
            return downloadFailure(
                code,
                category: .network,
                title: "Paywalls failed to download",
                body: "Paywalls failed to download. Check this device's connection and your Helium API key.",
                cta: .openUrl(label: "View Docs", url: Url.quickstart)
            )
        }
    }

    private func downloadFailure(
        _ code: String,
        category: DiagnosticCategory,
        title: String,
        body: String,
        cta: DiagnosticCta
    ) -> DiagnosticContent {
        DiagnosticContent(
            category: category,
            title: title,
            body: body,
            usersWillSee: UsersWillSee.seesNothingConsiderFallback,
            usersWillSeeLink: UsersWillSee.fallbackGuideLink,
            cta: cta,
            reasonCode: code
        )
    }

    // MARK: - INTEGRATION ERROR

    private func bundleUrlMissing(_ code: String, _ context: DiagnosticContext) -> DiagnosticContent {
        bundleProblem(
            code,
            title: "This paywall has no content to render",
            body: "The paywall for \"\(context.trigger)\" was served without a content bundle, so there "
                + "is nothing to render. Save the paywall again in the editor to publish its content; "
                + "if that does not help, copy the diagnostic report and contact Helium.",
            cta: .openUrl(label: "Open Paywall Editor", url: paywallEditorUrl(context))
        )
    }

    private func bundleUrlMalformed(_ code: String, _ context: DiagnosticContext) -> DiagnosticContent {
        bundleProblem(
            code,
            title: "The paywall's content address is malformed",
            body: "The content bundle address Helium received for \"\(context.trigger)\" is not a valid "
                + "web address, so its content was never downloaded. Save the paywall again in the "
                + "editor to publish a fresh one; if it stays malformed, copy the diagnostic report "
                + "and contact Helium.",
            cta: .openUrl(label: "Open Paywall Editor", url: paywallEditorUrl(context))
        )
    }

    private func bundleFetchForbidden(_ code: String, _ context: DiagnosticContext) -> DiagnosticContent {
        bundleProblem(
            code,
            title: "Access to the paywall's content was denied",
            body: "The server hosting the content for \"\(context.trigger)\" refused the download "
                + "(HTTP 403). Copy the diagnostic report and contact Helium.",
            cta: .copyReport
        )
    }

    private func bundleFetchNotFound(_ code: String, _ context: DiagnosticContext) -> DiagnosticContent {
        bundleProblem(
            code,
            title: "The paywall's content was not found",
            body: "The content for \"\(context.trigger)\" no longer exists where its configuration "
                + "points (HTTP 404). Save the paywall again in the editor to publish fresh content; "
                + "if it keeps happening, copy the diagnostic report and contact Helium.",
            cta: .openUrl(label: "Open Paywall Editor", url: paywallEditorUrl(context))
        )
    }

    private func bundleFetchGone(_ code: String, _ context: DiagnosticContext) -> DiagnosticContent {
        bundleProblem(
            code,
            title: "The paywall's content was removed",
            body: "The content for \"\(context.trigger)\" was permanently removed from hosting "
                + "(HTTP 410), usually because the paywall was deleted or republished. Save the "
                + "paywall again in the editor to publish fresh content.",
            cta: .openUrl(label: "Open Paywall Editor", url: paywallEditorUrl(context))
        )
    }

    private func bundleFetchUnreadable(_ code: String, _ context: DiagnosticContext) -> DiagnosticContent {
        bundleProblem(
            code,
            title: "The paywall's content is unreadable",
            body: "The content downloaded for \"\(context.trigger)\" could not be read as text, so it "
                + "cannot render. Copy the diagnostic report and contact Helium.",
            cta: .copyReport
        )
    }

    private func bundleProblem(_ code: String, title: String, body: String, cta: DiagnosticCta) -> DiagnosticContent {
        DiagnosticContent(
            category: .integrationError,
            title: title,
            body: body,
            usersWillSee: UsersWillSee.seesNothingConsiderFallback,
            usersWillSeeLink: UsersWillSee.fallbackGuideLink,
            cta: cta,
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
