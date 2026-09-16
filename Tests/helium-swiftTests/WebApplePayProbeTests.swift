import WebKit
import XCTest
@testable import Helium

final class WebApplePayProbeTests: XCTestCase {

    private let prodOrigin = "https://bundles.clickthrough.to"
    private let sandboxOrigin = "https://bundles-staging.clickthrough.to"

    override func setUp() {
        super.setUp()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        Helium.resetHelium()
        WebApplePayAvailability.shared.setReadinessForTesting(.unknown, probedAt: nil)
    }

    override func tearDown() {
        WebApplePayAvailability.shared.setReadinessForTesting(.unknown, probedAt: nil)
        Helium.resetHelium()
        super.tearDown()
    }

    // MARK: - Probe origin

    func testProbeOriginMatchesTheOriginCheckoutIsServedFrom() {
        XCTAssertEqual(PaddleBFFClient.sourcePageOrigin(for: "live_abc123"), prodOrigin)
        XCTAssertEqual(PaddleBFFClient.sourcePageOrigin(for: "test_abc123"), sandboxOrigin)
    }

    func testProbeHasNoOriginBeforeConfigArrives() {
        XCTAssertNil(WebApplePayAvailability.shared.probeOrigin())
    }

    func testProbeUsesTheOriginThePaddleTokenPointsAt() {
        injectConfig(makeWebCheckoutConfig(hasPaddleProducts: true, paddleClientToken: "live_abc123"))
        XCTAssertEqual(WebApplePayAvailability.shared.probeOrigin()?.absoluteString, prodOrigin)

        injectConfig(makeWebCheckoutConfig(hasPaddleProducts: true, paddleClientToken: "test_abc123"))
        XCTAssertEqual(WebApplePayAvailability.shared.probeOrigin()?.absoluteString, sandboxOrigin)
    }

    // MARK: - Probe

    @MainActor
    func testProbeAlwaysResolvesExactlyOnceWithinItsTimeout() async throws {
        let outcome = await makeProbe(timeout: 1).run()

        // The readiness depends on the Wallet of whatever runs this, so only the
        // contract is asserted: a probe answers, and it answers in bounded time.
        XCTAssertLessThan(outcome.durationMs, 5_000)
        if outcome.timedOut {
            XCTAssertEqual(outcome.readiness, .unknown)
        }
    }

    @MainActor
    func testProbeReportsUnknownWhenItRunsOutOfTime() async throws {
        let outcome = await makeProbe(timeout: 0).run()

        XCTAssertEqual(outcome.readiness, .unknown)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertEqual(outcome.failureReason, "timeout")
    }

    @MainActor
    func testProbeReportsUnknownWhenThePageFailsToLoad() async throws {
        let probe = makeProbe()

        probe.webView(WKWebView(), didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
        let result = await probe.run()

        XCTAssertEqual(result.readiness, .unknown)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.failureReason?.hasPrefix("didFailProvisional: "), true)
    }

    @MainActor
    func testProbeReportsUnknownWhenTheWebContentProcessDies() async throws {
        let probe = makeProbe()

        probe.webViewWebContentProcessDidTerminate(WKWebView())
        let result = await probe.run()

        XCTAssertEqual(result.readiness, .unknown)
        XCTAssertEqual(result.failureReason, "webContentProcessTerminated")
    }

    @MainActor
    func testOnlyTheFirstOfTheRacingOutcomesIsReported() async throws {
        let probe = makeProbe()
        let webView = WKWebView()

        probe.webView(webView, didFail: nil, withError: URLError(.timedOut))
        probe.webViewWebContentProcessDidTerminate(webView)
        probe.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
        let result = await probe.run()

        XCTAssertEqual(result.failureReason?.hasPrefix("didFail: "), true)
    }

    // MARK: - Probe result interpretation

    func testAnActiveCardMeansTheBrowserCanPay() {
        XCTAssertEqual(WebApplePayProbe.result(for: ["activeCard": true]).readiness, .ready)
        XCTAssertNil(WebApplePayProbe.result(for: ["activeCard": true]).failureReason)
    }

    func testNoActiveCardMeansTheBrowserCannotPay() {
        XCTAssertEqual(WebApplePayProbe.result(for: ["activeCard": false]).readiness, .notReady)
    }

    func testAPageThatCannotAnswerIsUnknownRatherThanNotReady() {
        let reported = WebApplePayProbe.result(for: ["error": "noApplePaySession"])
        XCTAssertEqual(reported.readiness, .unknown)
        XCTAssertEqual(reported.failureReason, "noApplePaySession")

        let unreadable = WebApplePayProbe.result(for: ["activeCard": "yes"])
        XCTAssertEqual(unreadable.readiness, .unknown)
        XCTAssertEqual(unreadable.failureReason, "malformedResult")

        XCTAssertEqual(WebApplePayProbe.result(for: [:]).readiness, .unknown)
    }

    // MARK: - Availability cache

    func testReadinessIsUnknownUntilAProbeAnswers() {
        XCTAssertEqual(WebApplePayAvailability.shared.readiness(), .unknown)
    }

    func testRefreshIsANoOpWithoutAPaddleClientToken() {
        WebApplePayAvailability.shared.refreshIfNeeded()

        XCTAssertEqual(WebApplePayAvailability.shared.readiness(), .unknown)
    }

    func testNoProbeRunsForAnAppThatDoesNotUseWebCheckout() {
        XCTAssertFalse(WebApplePayAvailability.shared.shouldProbe())
    }

    func testAMeasuredAnswerIsCachedAndAnUnknownOneIsNot() {
        let availability = WebApplePayAvailability.shared

        availability.apply(WebApplePayProbe.Outcome(
            readiness: .notReady,
            durationMs: 120,
            timedOut: false,
            failureReason: nil
        ))
        XCTAssertEqual(availability.readiness(), .notReady)
        XCTAssertTrue(availability.isCacheFresh())

        availability.apply(WebApplePayProbe.Outcome(
            readiness: .unknown,
            durationMs: 2_000,
            timedOut: true,
            failureReason: "timeout"
        ))
        XCTAssertEqual(availability.readiness(), .unknown)
        XCTAssertFalse(availability.isCacheFresh())
    }

    func testAMeasuredAnswerStaysCachedUntilItsIntervalElapses() {
        let availability = WebApplePayAvailability.shared
        let interval = availability.cacheDurationForTesting()

        availability.setReadinessForTesting(.ready, probedAt: Date())
        XCTAssertTrue(availability.isCacheFresh())

        availability.setReadinessForTesting(.ready, probedAt: Date(timeIntervalSinceNow: -interval - 1))
        XCTAssertFalse(availability.isCacheFresh())
    }

    func testAnUnknownAnswerDoesNotHoldOffTheNextProbe() {
        WebApplePayAvailability.shared.setReadinessForTesting(.unknown, probedAt: nil)

        XCTAssertFalse(WebApplePayAvailability.shared.isCacheFresh())
    }

    func testAnAnswerMeasuredAtAnotherOriginIsNotReused() {
        let availability = WebApplePayAvailability.shared
        injectConfig(makeWebCheckoutConfig(hasPaddleProducts: true, paddleClientToken: "test_abc123"))

        availability.setReadinessForTesting(
            .notReady,
            probedAt: Date(),
            origin: URL(string: prodOrigin)!
        )
        XCTAssertFalse(availability.isCacheFresh())

        availability.setReadinessForTesting(
            .notReady,
            probedAt: Date(),
            origin: URL(string: sandboxOrigin)!
        )
        XCTAssertTrue(availability.isCacheFresh())
    }

    func testResetDropsAMeasuredAnswer() {
        let availability = WebApplePayAvailability.shared
        availability.setReadinessForTesting(.notReady, probedAt: Date())

        availability.reset()

        XCTAssertEqual(availability.readiness(), .unknown)
        XCTAssertFalse(availability.isCacheFresh())
    }

    // MARK: - Routing

    func testPaddlePaywallIsSkippedUnlessApplePayWasMeasuredAsReady() {
        for readiness in [WebApplePayReadiness.notReady, .unknown] {
            XCTAssertEqual(
                paddleTriggerResult(readiness: readiness).fallbackReason,
                .webApplePayNotReady,
                "readiness: \(readiness)"
            )
        }
    }

    func testPaddlePaywallIsKeptWhenApplePayIsReady() {
        XCTAssertNotEqual(
            paddleTriggerResult(readiness: .ready).fallbackReason,
            .webApplePayNotReady
        )
    }

    func testPaywallWithoutPaddleProductsIgnoresApplePayReadiness() {
        XCTAssertNotEqual(
            paddleTriggerResult(hasPaddleProducts: false, readiness: .unknown).fallbackReason,
            .webApplePayNotReady
        )
    }

    // MARK: - Readiness reported to the server

    func testOnLaunchCarriesTheTriStateReadinessRatherThanABoolean() {
        for readiness in [WebApplePayReadiness.ready, .notReady, .unknown] {
            WebApplePayAvailability.shared.setReadinessForTesting(readiness)

            let payload = CodableUserContext.create(userTraits: nil).buildRequestPayload()

            XCTAssertEqual(payload["webApplePayReadiness"] as? String, readiness.rawValue)
        }
    }

    // MARK: - Diagnostics

    func testDiagnosticExplainsTheSkippedWebCheckoutAsExpectedBehavior() {
        let content = DiagnosticContentMapper().mapUnavailable(
            .webApplePayNotReady,
            context: DiagnosticContext(trigger: "web_trigger")
        )

        XCTAssertEqual(content.category, .expected)
        XCTAssertEqual(content.reasonCode, PaywallUnavailableReason.webApplePayNotReady.rawValue)
        XCTAssertTrue(content.usersWillSee.contains("in-app purchase paywall"))
    }

    // MARK: - Telemetry

    func testProbeEventCarriesReadinessLatencyAndNativeState() throws {
        let event = WebApplePayProbeCompleted(
            readiness: .notReady,
            durationMs: 480,
            timedOut: false,
            failureReason: nil,
            deviceCanMakePayments: true
        )

        XCTAssertEqual(event.name, "web_apple_pay_probe_completed")
        XCTAssertEqual(NSDictionary(dictionary: event.properties), NSDictionary(dictionary: [
            "readiness": "notReady",
            "durationMs": 480,
            "timedOut": false,
            "deviceCanMakePayments": true,
        ]))
    }

    func testProbeEventCarriesTheFailureReasonWhenItHasOne() throws {
        let event = WebApplePayProbeCompleted(
            readiness: .unknown,
            durationMs: 2_000,
            timedOut: true,
            failureReason: "timeout",
            deviceCanMakePayments: true
        )

        XCTAssertEqual(NSDictionary(dictionary: event.properties), NSDictionary(dictionary: [
            "readiness": "unknown",
            "durationMs": 2_000,
            "timedOut": true,
            "deviceCanMakePayments": true,
            "failureReason": "timeout",
        ]))
    }

    // MARK: - Helpers

    @MainActor
    private func makeProbe(timeout: TimeInterval = 30) -> WebApplePayProbe {
        return WebApplePayProbe(origin: URL(string: prodOrigin)!, timeout: timeout)
    }

    private func paddleTriggerResult(
        hasPaddleProducts: Bool = true,
        readiness: WebApplePayReadiness
    ) -> PaywallViewResult {
        Helium.shared.markInitializedForTesting()
        Helium.config.enableExternalWebCheckout(
            redirectURL: "myapp://checkout/return",
            paymentProcessors: .all
        )
        Helium.config.allowWebCheckoutWithoutUserId = true
        injectConfig(makeWebCheckoutConfig(hasPaddleProducts: hasPaddleProducts))
        WebApplePayAvailability.shared.setReadinessForTesting(readiness)

        return HeliumPaywallPresenter.shared.upsellViewResultFor(
            trigger: "web_trigger",
            presentationContext: PaywallPresentationContext.empty
        )
    }

    private func makeWebCheckoutConfig(
        hasPaddleProducts: Bool,
        paddleClientToken: String? = nil
    ) -> HeliumFetchedConfig {
        var paywallInfo = makeTestPaywallInfo(trigger: "web_trigger")
        if hasPaddleProducts {
            paywallInfo.productsOfferedPaddle = ["paddle_product:pri_1"]
        }

        var config = makeTestConfig(triggers: ["web_trigger": paywallInfo])
        config.paddleClientToken = paddleClientToken
        return config
    }
}
