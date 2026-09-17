import WebKit
import XCTest
@testable import Helium

final class WebApplePayProbeTests: XCTestCase {

    private let prodOrigin = "https://bundles.clickthrough.to"

    override func setUp() {
        super.setUp()
        HeliumAnalyticsManager.shared.disableAnalyticsForTesting()
        Helium.resetHelium()
        Helium.config.enableWebApplePayReadiness = true
        ApplePayHelper.shared.setCanMakePaymentsForTesting(true)
        WebApplePayAvailability.shared.setReadinessForTesting(.unknown(.notMeasured), probed: false)
    }

    override func tearDown() {
        WebApplePayAvailability.shared.setReadinessForTesting(.unknown(.notMeasured), probed: false)
        ApplePayHelper.shared.setCanMakePaymentsForTesting(nil)
        Helium.config.disableExternalWebCheckout()
        Helium.config.allowWebCheckoutWithoutUserId = false
        Helium.config.enableWebApplePayReadiness = false
        Helium.resetHelium()
        super.tearDown()
    }

    // MARK: - Probe origin

    func testProbeMeasuresTheOriginCheckoutIsServedFrom() {
        XCTAssertEqual(WebApplePayAvailability.probeOrigin?.absoluteString, prodOrigin)
    }

    // MARK: - Probe

    @MainActor
    func testProbeAlwaysResolvesExactlyOnceWithinItsTimeout() async throws {
        let outcome = await makeProbe(timeout: 1).run()

        // The readiness depends on the Wallet of whatever runs this, so only the
        // contract is asserted: a probe answers, and it answers in bounded time.
        XCTAssertLessThan(outcome.durationMs, 5_000)
        if outcome.timedOut {
            XCTAssertEqual(outcome.readiness, .unknown(.timedOut))
        }
    }

    @MainActor
    func testProbeReportsUnknownWhenItRunsOutOfTime() async throws {
        let outcome = await makeProbe(timeout: 0).run()

        XCTAssertEqual(outcome.readiness, .unknown(.timedOut))
        XCTAssertTrue(outcome.timedOut)
        XCTAssertEqual(outcome.failureReason, "timeout")
    }

    @MainActor
    func testProbeReportsUnknownWhenThePageFailsToLoad() async throws {
        let probe = makeProbe()

        probe.webView(WKWebView(), didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
        let result = await probe.run()

        XCTAssertEqual(result.readiness, .unknown(.probeFailed))
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.failureReason?.hasPrefix("didFailProvisional: "), true)
    }

    @MainActor
    func testProbeReportsUnknownWhenTheWebContentProcessDies() async throws {
        let probe = makeProbe()

        probe.webViewWebContentProcessDidTerminate(WKWebView())
        let result = await probe.run()

        XCTAssertEqual(result.readiness, .unknown(.probeFailed))
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
        XCTAssertEqual(reported.readiness, .unknown(.noApplePayAPI))
        XCTAssertEqual(reported.failureReason, "noApplePaySession")

        let rejected = WebApplePayProbe.result(for: ["error": "activeCardRejected: boom"])
        XCTAssertEqual(rejected.readiness, .unknown(.apiError))

        let unreadable = WebApplePayProbe.result(for: ["activeCard": "yes"])
        XCTAssertEqual(unreadable.readiness, .unknown(.apiError))
        XCTAssertEqual(unreadable.failureReason, "malformedResult")

        XCTAssertEqual(WebApplePayProbe.result(for: [:]).readiness, .unknown(.apiError))
    }

    func testAnUnknownReadinessNamesWhyItIsUnknown() {
        XCTAssertEqual(WebApplePayReadiness.unknown(.timedOut).rawValue, "unknown:timedOut")
        XCTAssertEqual(WebApplePayReadiness.ready.rawValue, "ready")
        XCTAssertNotEqual(WebApplePayReadiness.unknown(.timedOut), .unknown(.probeFailed))
    }

    // MARK: - Availability cache

    func testReadinessIsUnknownUntilAProbeAnswers() {
        XCTAssertTrue(WebApplePayAvailability.shared.readiness().isUnknown)
    }

    func testNoProbeRunsForAnAppThatDoesNotUseWebCheckout() {
        Helium.config.disableExternalWebCheckout()

        XCTAssertFalse(WebApplePayAvailability.shared.shouldProbe())
    }

    func testAMeasuredAnswerIsRememberedAndAnUnknownOneIsNot() throws {
        let availability = makeAvailability()

        availability.apply(makeOutcome(readiness: .notReady))
        XCTAssertEqual(availability.readiness(), .notReady)
        XCTAssertEqual(availability.persistedReadinessForTesting(), .notReady)

        availability.apply(makeOutcome(readiness: .unknown(.timedOut), timedOut: true))
        XCTAssertEqual(availability.readiness(), .unknown(.timedOut))
        XCTAssertEqual(availability.persistedReadinessForTesting(), .notReady)
    }

    func testAMeasuredAnswerIsServedImmediatelyOnTheNextLaunch() throws {
        let defaults = try makeIsolatedDefaults()
        makeAvailability(defaults: defaults).apply(makeOutcome(readiness: .notReady))

        let nextLaunch = makeAvailability(defaults: defaults)

        XCTAssertEqual(nextLaunch.readiness(), .notReady)
        XCTAssertEqual(nextLaunch.persistedReadinessForTesting(), .notReady)
    }

    func testADeviceThatCannotPayOutranksAMeasuredAnswer() throws {
        let availability = makeAvailability()
        availability.apply(makeOutcome(readiness: .ready))
        XCTAssertEqual(availability.readiness(), .ready)

        ApplePayHelper.shared.setCanMakePaymentsForTesting(false)

        XCTAssertEqual(availability.readiness(), .unknown(.deviceCannotPay))
    }

    // MARK: - Opting in

    func testAnAppThatHasNotOptedInIsNeverProbedAndIsReportedReady() {
        Helium.config.enableWebApplePayReadiness = false
        configureWebCheckout(processor: .paddle)
        WebApplePayAvailability.shared.setReadinessForTesting(.notReady, probed: false)

        XCTAssertFalse(WebApplePayAvailability.shared.shouldProbe())
        XCTAssertEqual(WebApplePayAvailability.shared.readiness(), .ready)
    }

    // MARK: - Measuring before the launch request

    func testAFirstLaunchWithNothingStoredWaitsForAMeasurement() throws {
        configureWebCheckout(hasPaddleProducts: true)
        let availability = makeAvailability()

        XCTAssertTrue(availability.needsMeasurementBeforeLaunch())
    }

    func testALaunchWithAStoredMeasurementDoesNotWait() throws {
        configureWebCheckout(hasPaddleProducts: true)
        let defaults = try makeIsolatedDefaults()
        makeAvailability(defaults: defaults).apply(makeOutcome(readiness: .notReady))

        let nextLaunch = makeAvailability(defaults: defaults)

        XCTAssertFalse(nextLaunch.needsMeasurementBeforeLaunch())
        XCTAssertEqual(nextLaunch.readiness(), .notReady)
    }

    func testALaunchAfterAFailedProbeDoesNotWaitAgain() throws {
        configureWebCheckout(hasPaddleProducts: true)
        let defaults = try makeIsolatedDefaults()
        makeAvailability(defaults: defaults).apply(makeOutcome(readiness: .unknown(.timedOut), timedOut: true))

        let nextLaunch = makeAvailability(defaults: defaults)

        XCTAssertFalse(nextLaunch.needsMeasurementBeforeLaunch())
        XCTAssertNil(nextLaunch.persistedReadinessForTesting())
    }

    func testALaunchThatWouldNotProbeAtAllDoesNotWait() throws {
        configureWebCheckout(hasPaddleProducts: true)
        Helium.config.enableWebApplePayReadiness = false

        XCTAssertFalse(makeAvailability().needsMeasurementBeforeLaunch())

        Helium.config.enableWebApplePayReadiness = true
        ApplePayHelper.shared.setCanMakePaymentsForTesting(false)

        XCTAssertFalse(makeAvailability().needsMeasurementBeforeLaunch())
    }

    func testALaunchGivesUpOnAProbeSlowerThanItsBudget() async throws {
        let availability = makeAvailability()

        let startedAt = Date()
        await availability.awaitMeasurement(upTo: 0.1)

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        XCTAssertEqual(availability.readiness(), .unknown(.notMeasured))
    }

    func testAMeasurementThatLandsAfterTheBudgetIsStillStored() async throws {
        configureWebCheckout(hasPaddleProducts: true)
        let defaults = try makeIsolatedDefaults()
        let availability = makeAvailability(defaults: defaults)

        await availability.awaitMeasurement(upTo: 0.1)
        availability.apply(makeOutcome(readiness: .notReady))

        XCTAssertEqual(availability.persistedReadinessForTesting(), .notReady)
        XCTAssertFalse(makeAvailability(defaults: defaults).needsMeasurementBeforeLaunch())
    }

    func testAWaitingLaunchResumesAsSoonAsTheMeasurementLands() async throws {
        let availability = makeAvailability()

        let startedAt = Date()
        async let waited: Void = availability.awaitMeasurement(upTo: 30)
        try await Task.sleep(nanoseconds: 50_000_000)
        availability.apply(makeOutcome(readiness: .ready))
        await waited

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
        XCTAssertEqual(availability.readiness(), .ready)
    }

    func testOnlyOneRefreshRunsPerLaunch() {
        configureWebCheckout(processor: .paddle)
        WebApplePayAvailability.shared.setReadinessForTesting(.ready, probed: true)

        XCTAssertFalse(WebApplePayAvailability.shared.shouldProbe())
    }

    // MARK: - Routing

    func testReadinessDoesNotDecideWhichPaywallIsShown() {
        for processor in [WebProductProcessor.paddle, .stripe] {
            for readiness in [WebApplePayReadiness.notReady, .unknown(.timedOut), .unknown(.noApplePayAPI)] {
                XCTAssertEqual(
                    webTriggerResult(processor: processor, readiness: readiness).fallbackReason,
                    webTriggerResult(processor: processor, readiness: .ready).fallbackReason,
                    "processor: \(processor), readiness: \(readiness)"
                )
            }
        }
    }

    // MARK: - Readiness reported to the server

    func testOnLaunchCarriesTheTriStateReadinessRatherThanABoolean() {
        for readiness in [WebApplePayReadiness.ready, .notReady, .unknown(.probeFailed)] {
            WebApplePayAvailability.shared.setReadinessForTesting(readiness)

            let payload = CodableUserContext.create(userTraits: nil).buildRequestPayload()

            XCTAssertEqual(payload["webApplePayReadiness"] as? String, readiness.rawValue)
        }
    }

    func testOnLaunchReportsReadyForAnAppThatHasNotOptedIn() {
        Helium.config.enableWebApplePayReadiness = false
        WebApplePayAvailability.shared.setReadinessForTesting(.notReady)

        let payload = CodableUserContext.create(userTraits: nil).buildRequestPayload()

        XCTAssertEqual(payload["webApplePayReadiness"] as? String, "ready")
    }

    // MARK: - Telemetry

    func testProbeEventCarriesReadinessLatencyAndNativeState() throws {
        let event = WebApplePayProbeCompleted(
            readiness: .notReady,
            durationMs: 480,
            timedOut: false,
            failureReason: nil,
            deviceCanMakePayments: true,
            launchWaitMs: nil,
            servedFromCache: nil,
            cacheWasCorrect: nil
        )

        XCTAssertEqual(event.name, "web_apple_pay_probe_completed")
        XCTAssertEqual(NSDictionary(dictionary: event.properties), NSDictionary(dictionary: [
            "readiness": "notReady",
            "durationMs": 480,
            "timedOut": false,
            "deviceCanMakePayments": true,
            "cacheHit": false,
        ]))
    }

    func testProbeEventSaysWhetherTheCachedAnswerWasStillCorrect() throws {
        let event = WebApplePayProbeCompleted(
            readiness: .notReady,
            durationMs: 480,
            timedOut: false,
            failureReason: nil,
            deviceCanMakePayments: true,
            launchWaitMs: nil,
            servedFromCache: "ready",
            cacheWasCorrect: false
        )

        XCTAssertEqual(NSDictionary(dictionary: event.properties), NSDictionary(dictionary: [
            "readiness": "notReady",
            "durationMs": 480,
            "timedOut": false,
            "deviceCanMakePayments": true,
            "cacheHit": true,
            "servedFromCache": "ready",
            "cacheWasCorrect": false,
        ]))
    }

    func testCacheCorrectnessIsUnverifiedWhenTheProbeMeasuredNothing() throws {
        XCTAssertNil(WebApplePayAvailability.cacheCorrectness(of: .ready, against: .unknown(.timedOut)))
        XCTAssertNil(WebApplePayAvailability.cacheCorrectness(of: nil, against: .ready))
        XCTAssertEqual(WebApplePayAvailability.cacheCorrectness(of: .ready, against: .ready), true)
        XCTAssertEqual(WebApplePayAvailability.cacheCorrectness(of: .ready, against: .notReady), false)
    }

    func testProbeEventCarriesTheFailureReasonWhenItHasOne() throws {
        let event = WebApplePayProbeCompleted(
            readiness: .unknown(.timedOut),
            durationMs: 2_000,
            timedOut: true,
            failureReason: "timeout",
            deviceCanMakePayments: true,
            launchWaitMs: nil,
            servedFromCache: nil,
            cacheWasCorrect: nil
        )

        XCTAssertEqual(NSDictionary(dictionary: event.properties), NSDictionary(dictionary: [
            "readiness": "unknown:timedOut",
            "durationMs": 2_000,
            "timedOut": true,
            "deviceCanMakePayments": true,
            "cacheHit": false,
            "failureReason": "timeout",
        ]))
    }

    func testProbeEventCarriesHowLongTheLaunchWasHeld() throws {
        let event = WebApplePayProbeCompleted(
            readiness: .ready,
            durationMs: 3_400,
            timedOut: false,
            failureReason: nil,
            deviceCanMakePayments: true,
            launchWaitMs: 2_003,
            servedFromCache: nil,
            cacheWasCorrect: nil
        )

        XCTAssertEqual(NSDictionary(dictionary: event.properties), NSDictionary(dictionary: [
            "readiness": "ready",
            "durationMs": 3_400,
            "timedOut": false,
            "deviceCanMakePayments": true,
            "cacheHit": false,
            "launchWaitMs": 2_003,
        ]))
    }

    func testALaunchThatWaitsRecordsHowLongItWasHeld() async throws {
        let availability = makeAvailability()

        await availability.awaitMeasurement(upTo: 0.1)

        let heldMs = try XCTUnwrap(availability.launchWaitMsForTesting())
        XCTAssertGreaterThanOrEqual(heldMs, 90)
        XCTAssertLessThan(heldMs, 2_000)
    }

    func testALaunchThatDoesNotWaitRecordsNoHeldTime() throws {
        let availability = makeAvailability()

        availability.apply(makeOutcome(readiness: .ready))

        XCTAssertNil(availability.launchWaitMsForTesting())
    }

    // MARK: - Helpers

    private enum WebProductProcessor {
        case paddle
        case stripe
    }

    @MainActor
    private func makeProbe(timeout: TimeInterval = 30) -> WebApplePayProbe {
        return WebApplePayProbe(origin: URL(string: prodOrigin)!, timeout: timeout)
    }

    private func configureWebCheckout(processor: WebProductProcessor?) {
        Helium.shared.markInitializedForTesting()
        Helium.config.enableExternalWebCheckout(
            redirectURL: "myapp://checkout/return",
            paymentProcessors: .all
        )
        Helium.config.allowWebCheckoutWithoutUserId = true
        injectConfig(makeWebCheckoutConfig(processor: processor))
    }

    private func webTriggerResult(
        processor: WebProductProcessor?,
        readiness: WebApplePayReadiness
    ) -> PaywallViewResult {
        configureWebCheckout(processor: processor)
        WebApplePayAvailability.shared.setReadinessForTesting(readiness)

        return HeliumPaywallPresenter.shared.upsellViewResultFor(
            trigger: "web_trigger",
            presentationContext: PaywallPresentationContext.empty
        )
    }

    private func makeAvailability(defaults: UserDefaults? = nil) -> WebApplePayAvailability {
        let defaults = defaults ?? (try? makeIsolatedDefaults())
        guard let defaults else { return WebApplePayAvailability() }
        return WebApplePayAvailability(storage: HeliumStorage(defaults: defaults))
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suite = "com.tryhelium.tests.\(name).\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func makeOutcome(
        readiness: WebApplePayReadiness,
        timedOut: Bool = false
    ) -> WebApplePayProbe.Outcome {
        WebApplePayProbe.Outcome(
            readiness: readiness,
            durationMs: 120,
            timedOut: timedOut,
            failureReason: timedOut ? "timeout" : nil
        )
    }

    private func makeWebCheckoutConfig(processor: WebProductProcessor?) -> HeliumFetchedConfig {
        var paywallInfo = makeTestPaywallInfo(trigger: "web_trigger")
        switch processor {
        case .paddle:
            paywallInfo.productsOfferedPaddle = ["paddle_product:pri_1"]
        case .stripe:
            paywallInfo.productsOfferedStripe = ["stripe_product:price_1"]
        case nil:
            break
        }
        return makeTestConfig(triggers: ["web_trigger": paywallInfo])
    }
}
