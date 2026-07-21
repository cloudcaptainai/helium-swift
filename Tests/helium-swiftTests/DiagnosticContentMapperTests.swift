import XCTest
@testable import Helium

final class DiagnosticContentMapperTests: XCTestCase {

    private let mapper = DiagnosticContentMapper()
    private let trigger = "onboarding_end"
    private let fallbackGuideUrl = "https://docs.tryhelium.com/guides/fallback-bundle"

    private func context(paywallId: String? = nil, processors: WebCheckoutProcessors = []) -> DiagnosticContext {
        DiagnosticContext(trigger: trigger, paywallId: paywallId, webCheckoutProcessors: processors)
    }

    private func content(for reason: PaywallUnavailableReason?) -> DiagnosticContent {
        mapper.mapUnavailable(reason, context: context())
    }

    /// Every authored record: both skip reasons, every unavailable reason, and the nil path.
    private func allContent() -> [DiagnosticContent] {
        PaywallSkippedReason.allCases.map { mapper.mapSkip($0) }
            + PaywallUnavailableReason.allCases.map { content(for: $0) }
            + [content(for: nil)]
    }

    // MARK: - Forward compat: no raw codes leak into displayed prose

    func testNoUnavailableReasonLeaksItsRawCodeIntoProse() {
        for reason in PaywallUnavailableReason.allCases {
            let content = content(for: reason)
            for text in [content.title, content.body, content.usersWillSee] {
                XCTAssertFalse(
                    text.contains(reason.rawValue),
                    "\(reason.rawValue) leaks its raw code into displayed prose: \(text)"
                )
            }
        }
    }

    func testEveryUnavailableReasonIsFullyAuthored() {
        for reason in PaywallUnavailableReason.allCases {
            let content = content(for: reason)
            XCTAssertFalse(content.title.isEmpty, "\(reason.rawValue) has a blank title")
            XCTAssertFalse(content.body.isEmpty, "\(reason.rawValue) has a blank body")
            XCTAssertFalse(content.usersWillSee.isEmpty, "\(reason.rawValue) has no users copy")
            XCTAssertEqual(content.reasonCode, reason.rawValue)
        }
    }

    /// The CTA and the users-will-see link own every URL, so no prose field may contain one.
    func testNoProseContainsAUrl() {
        for content in allContent() {
            for prose in [content.title, content.body, content.usersWillSee] {
                XCTAssertFalse(
                    prose.contains("http"),
                    "\(content.reasonCode) embeds a URL in prose: \(prose)"
                )
            }
        }
    }

    /// A malformed URL renders a remediation row that silently does nothing when tapped.
    func testEveryAuthoredLinkIsOpenable() {
        for content in allContent() {
            guard let link = content.usersWillSeeLink else { continue }
            XCTAssertNotNil(URL(string: link.url), "\(content.reasonCode) has an unopenable link")
            XCTAssertFalse(link.label.isEmpty, "\(content.reasonCode) has an unlabelled link")
        }
    }

    func testNilReasonRendersUnknownCopy() {
        let content = content(for: nil)

        XCTAssertEqual(content.category, .integrationError)
        XCTAssertEqual(content.title, "The paywall couldn't be shown")
        XCTAssertEqual(content.reasonCode, "unknown")
        XCTAssertEqual(content.cta, .copyReport)
    }

    // MARK: - Category mapping

    func testSkipReasonsAreExpected() {
        for reason in [PaywallSkippedReason.targetingHoldout, .alreadyEntitled] {
            XCTAssertEqual(mapper.mapSkip(reason).category, .expected)
        }
    }

    func testSetupReasonsAreCategorisedAsSetup() {
        let setup: [PaywallUnavailableReason] = [
            .notInitialized, .noRootController, .triggerHasNoPaywall, .noProductsIOS,
            .webCheckoutNoCustomUserId, .webCheckoutNotEnabled,
        ]
        for reason in setup {
            XCTAssertEqual(content(for: reason).category, .setup, reason.rawValue)
        }
    }

    func testNetworkReasonsAreCategorisedAsNetwork() {
        let network: [PaywallUnavailableReason] = [
            .paywallsNotDownloaded, .configFetchInProgress, .bundlesFetchInProgress,
            .productsFetchInProgress, .paywallsDownloadFail,
        ]
        for reason in network {
            XCTAssertEqual(content(for: reason).category, .network, reason.rawValue)
        }
    }

    func testIntegrationErrorReasonsAreCategorisedAsIntegrationError() {
        let errors: [PaywallUnavailableReason] = [
            .couldNotFindBundleUrl, .bundleFetchInvalidUrlDetected, .bundleFetchInvalidUrl,
            .bundleFetch403, .bundleFetch404, .bundleFetch410, .bundleFetchCannotDecodeContent,
            .webviewRenderFail, .bridgingError, .secondTryNoMatch, .invalidResolvedConfig,
        ]
        for reason in errors {
            XCTAssertEqual(content(for: reason).category, .integrationError, reason.rawValue)
        }
    }

    func testIntentionalNonPresentationIsExpected() {
        for reason in [PaywallUnavailableReason.alreadyPresented, .forceShowFallback] {
            XCTAssertEqual(content(for: reason).category, .expected, reason.rawValue)
        }
    }

    // MARK: - Product vocabulary

    /// Helium sells digital in-app products and subscriptions. Generic commerce phrasing
    /// ("nothing to sell", "items", "goods") misdescribes the product and misdirects the fix.
    func testNoProductsCopyNamesInAppProductsAndTheStore() {
        let content = content(for: .noProductsIOS)

        XCTAssertTrue(content.body.contains("in-app products"))
        XCTAssertTrue(content.body.contains("subscriptions"))
        XCTAssertTrue(content.body.contains("App Store"))
    }

    func testNoCopyUsesGenericCommercePhrasing() {
        let banned = ["nothing to sell", "items", "goods", "merchandise"]

        for reason in PaywallUnavailableReason.allCases {
            let content = content(for: reason)
            let prose = "\(content.title) \(content.body) \(content.usersWillSee)".lowercased()
            for phrase in banned {
                XCTAssertFalse(prose.contains(phrase), "\(reason.rawValue) uses '\(phrase)'")
            }
        }
    }

    // MARK: - Reviewed copy

    /// "Holdout" is internal vocabulary — the dashboard calls this "show no paywall".
    func testTargetingSkipAvoidsHoldoutVocabulary() {
        let content = mapper.mapSkip(.targetingHoldout)

        XCTAssertEqual(content.title, "Paywall skipped")
        let prose = "\(content.title) \(content.body) \(content.usersWillSee)".lowercased()
        XCTAssertFalse(prose.contains("holdout"))
    }

    func testAlreadyEntitledTitleIsSimplified() {
        XCTAssertEqual(mapper.mapSkip(.alreadyEntitled).title, "Already subscribed")
    }

    func testAlreadyEntitledUsersLineStatesOnlyTheSplitOutcome() {
        XCTAssertEqual(
            mapper.mapSkip(.alreadyEntitled).usersWillSee,
            "Subscribed users see no paywall; users without the entitlement see it normally."
        )
    }

    /// The trigger here is the second-try trigger, not the paywall the user is looking at.
    func testSecondTryMissNamesTheTriggerAndLinksTheEditor() {
        let content = content(for: .secondTryNoMatch)

        XCTAssertEqual(content.title, "No second try paywall found")
        XCTAssertTrue(content.body.contains("\"\(trigger)\""))
        XCTAssertEqual(
            content.cta,
            .openUrl(label: "Open Paywall Editor", url: "https://app.tryhelium.com/paywalls")
        )
    }

    /// The modal only presents when nothing rendered, so a forced fallback reaching it means the
    /// fallback itself failed. The title and body state the cause — true in both the modal and the
    /// fallback-shown log — while the outcome lives in the users line the modal alone renders.
    func testForcedFallbackTitleStatesTheCauseAndTheUsersLineTheModalOnlyOutcome() {
        let content = content(for: .forceShowFallback)

        XCTAssertEqual(content.title, "Fallback paywall forced for this trigger")
        XCTAssertTrue(content.body.contains("configured to force the bundled fallback"))
        XCTAssertTrue(content.usersWillSee.contains("could not be rendered"))
    }

    // MARK: - Context enrichment

    func testPaywallEditorCtaDeepLinksWhenThePaywallIdResolves() {
        let content = mapper.mapUnavailable(.noProductsIOS, context: context(paywallId: "abc-123"))

        XCTAssertEqual(
            content.cta,
            .openUrl(label: "Open Paywall Editor", url: "https://app.tryhelium.com/paywalls/abc-123")
        )
    }

    func testPaywallEditorCtaUsesThePaywallListWhenTheIdIsUnknown() {
        XCTAssertEqual(
            content(for: .noProductsIOS).cta,
            .openUrl(label: "Open Paywall Editor", url: "https://app.tryhelium.com/paywalls")
        )
    }

    func testWebCheckoutNotEnabledAppendsTheEnabledProcessors() {
        let content = mapper.mapUnavailable(
            .webCheckoutNotEnabled,
            context: context(processors: .stripe)
        )

        XCTAssertTrue(content.body.contains("Currently enabled: stripe."))
    }

    /// The empty set is the config default, so this is the state most likely to produce the reason.
    func testWebCheckoutNotEnabledOmitsProcessorsWhenNoneAreEnabled() {
        let content = mapper.mapUnavailable(
            .webCheckoutNotEnabled,
            context: context(processors: [])
        )

        XCTAssertFalse(content.body.contains("Currently enabled"))
    }

    /// The remediation must name an API that exists — `Helium.identify.userId` is the public
    /// surface for setting a custom user ID.
    func testWebCheckoutUserIdCopyNamesTheIdentifyApi() {
        XCTAssertTrue(
            content(for: .webCheckoutNoCustomUserId).body.contains("Helium.identify.userId")
        )
    }

    // MARK: - CTAs

    func testUnactionableFailuresCopyTheReport() {
        let errors: [PaywallUnavailableReason] = [
            .couldNotFindBundleUrl, .webviewRenderFail, .bridgingError, .invalidResolvedConfig,
        ]
        for reason in errors {
            XCTAssertEqual(content(for: reason).cta, .copyReport, reason.rawValue)
        }
    }

    func testTargetingSkipOpensWorkflows() {
        XCTAssertEqual(
            mapper.mapSkip(.targetingHoldout).cta,
            .openUrl(label: "Open Workflows", url: "https://app.tryhelium.com/workflows")
        )
    }

    func testAlreadyEntitledOpensEntitlementDocs() {
        XCTAssertEqual(
            mapper.mapSkip(.alreadyEntitled).cta,
            .openUrl(
                label: "Entitlement Docs",
                url: "https://docs.tryhelium.com/sdk/quickstart-ios#checking-subscription-status-%26-entitlements"
            )
        )
    }

    /// Existing grep-based log workflows key off this wording.
    func testAlreadyPresentedKeepsItsExistingLogWording() {
        XCTAssertEqual(
            content(for: .alreadyPresented).title,
            "A Helium paywall is already being presented"
        )
    }

    // MARK: - Users-will-see matrix

    /// A bundled fallback would have covered these users, so the outcome points at the guide.
    func testFallbackCoverableReasonsSuggestTheFallbackGuide() {
        let coverable: [PaywallUnavailableReason] = [
            .triggerHasNoPaywall, .noProductsIOS,
            .webCheckoutNoCustomUserId, .webCheckoutNotEnabled,
            .paywallsNotDownloaded, .configFetchInProgress, .bundlesFetchInProgress,
            .productsFetchInProgress, .paywallsDownloadFail,
            .couldNotFindBundleUrl, .bundleFetchInvalidUrlDetected, .bundleFetchInvalidUrl,
            .bundleFetch403, .bundleFetch404, .bundleFetch410, .bundleFetchCannotDecodeContent,
            .webviewRenderFail, .bridgingError, .invalidResolvedConfig,
        ]

        for reason in coverable {
            XCTAssertEqual(
                content(for: reason).usersWillSeeLink?.url,
                fallbackGuideUrl,
                reason.rawValue
            )
        }
    }

    /// These stop the SDK before the loader runs, so no fallback could render either.
    func testPreLoaderFailuresDoNotAdviseAFallback() {
        for reason in [PaywallUnavailableReason.notInitialized, .noRootController] {
            let content = content(for: reason)
            XCTAssertNil(content.usersWillSeeLink, reason.rawValue)
            XCTAssertFalse(content.usersWillSee.contains("Consider adding"), reason.rawValue)
            XCTAssertTrue(content.usersWillSee.contains("no fallback can load"), reason.rawValue)
        }
    }

    /// Waiting on the download is the one miss real users experience with visible UI.
    func testPaywallsStillDownloadingNamesTheLoadingState() {
        XCTAssertTrue(
            content(for: .paywallsNotDownloaded).usersWillSee.contains("loading indication")
        )
    }

    /// notInitialized fires only when initialize() was never called, not while it is in flight —
    /// `initialized` is set synchronously at the top of initialize().
    func testNotInitializedBodySaysInitializeWasNeverCalled() {
        let body = content(for: .notInitialized).body

        XCTAssertTrue(body.contains("never called"))
        XCTAssertFalse(body.contains("completed"))
    }
}
