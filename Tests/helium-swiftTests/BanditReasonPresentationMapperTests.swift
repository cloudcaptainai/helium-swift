import XCTest
@testable import Helium

final class BanditReasonPresentationMapperTests: XCTestCase {

    private let mapper = BanditReasonPresentationMapper()

    static let paddleGeoSentence = "App-to-Web checkout is only available to users verified as located in the US. "
        + "This device's country signals were missing or not US, so the paywall's Paddle products could not be offered."

    private let sentences: [(sentence: String, kind: BanditReasonKind, title: String, fix: String)] = [
        (paddleGeoSentence,
         .paddleGeo, "Paddle needs a US buyer",
         "Target this paywall at a US audience, or give the trigger a fallback rule."),
        ("App-to-Web checkout for users in California requires the consent modal, which this SDK version or the org's configuration does not support yet, so the paywall's Paddle products could not be offered.",
         .paddleCaliforniaConsent, "California needs the consent modal",
         "Update to iOS SDK 4.7.1 or newer and enable the consent modal for this org."),
        ("This paywall offers Paddle products, but the organization's Paddle credentials are missing or could not be loaded.",
         .paddleCredentials, "Paddle credentials missing",
         "Reconnect Paddle under Integrations, then publish the paywall again."),
        ("This paywall uses App-to-Web Stripe checkout, which requires Apple Pay to be available in the browser. The device reported it as unavailable.",
         .applePayUnavailable, "Apple Pay not available",
         "Test on a device with a card in Wallet, or give the trigger a fallback rule."),
        ("This paywall uses in-app Stripe checkout, which requires Apple Pay. The device reported it as unavailable.",
         .applePayUnavailable, "Apple Pay not available",
         "Test on a device with a card in Wallet, or give the trigger a fallback rule."),
        ("A paywall was selected for this trigger, but Helium could not resolve it to a single published version.",
         .versionUnresolved, "Paywall version not published",
         "Open the paywall in the editor and publish it."),
        ("The user did not match any targeting rule on the connected workflow, and the workflow has no default paywall or experiment to fall back to.",
         .noTargetingMatch, "No targeting rule matched",
         "Add a rule for everyone else, or set a default paywall on the workflow."),
        ("The connected workflow has no default paywall or experiment configured.",
         .workflowNoPaywall, "Workflow has no default paywall",
         "Set a default paywall or experiment on the workflow."),
        ("The connected workflow's experiment has no valid allocation metadata, so no paywall could be selected.",
         .experimentMisconfigured, "Experiment misconfigured",
         "Open the experiment and fix its allocation, then take it live again."),
        ("Helium hit an error while evaluating the connected workflow.",
         .workflowError, "Workflow evaluation failed",
         "Copy the diagnostic report and contact Helium."),
        ("No workflow is connected to this trigger.",
         .noWorkflow, "No workflow on this trigger",
         "Add the trigger to a workflow in the dashboard."),
    ]

    func testEveryServerSentenceResolvesToItsKind() {
        for entry in sentences {
            XCTAssertEqual(BanditReasonKind(sentence: entry.sentence), entry.kind, entry.sentence)
        }
    }

    func testEveryServerSentenceGetsItsHeadlineAndFix() {
        for entry in sentences {
            let presentation = mapper.map(entry.sentence)
            XCTAssertEqual(presentation.title, entry.title, entry.sentence)
            XCTAssertEqual(presentation.fix, entry.fix, entry.sentence)
        }
    }

    func testHeadlinesStayShort() {
        for entry in sentences {
            let words = mapper.map(entry.sentence).title.split(separator: " ").count
            XCTAssertTrue((2...5).contains(words), "\(entry.title) has \(words) words")
        }
    }

    func testMatchingIgnoresCase() {
        XCTAssertEqual(BanditReasonKind(sentence: "NO WORKFLOW IS CONNECTED TO THIS TRIGGER."), .noWorkflow)
    }

    func testKindAndSentenceMapToTheSamePresentation() {
        for entry in sentences {
            XCTAssertEqual(mapper.map(entry.sentence), mapper.map(entry.kind), entry.sentence)
        }
    }

    func testUnrecognisedSentenceKeepsTheGenericHeadlineAndNoFix() {
        let presentation = mapper.map("Something new the server started saying.")

        XCTAssertNil(BanditReasonKind(sentence: "Something new the server started saying."))
        XCTAssertEqual(presentation, .unrecognised)
        XCTAssertEqual(presentation.title, "No paywall was resolved for this trigger")
        XCTAssertNil(presentation.fix)
        XCTAssertTrue(presentation.checks.isEmpty)
    }

    func testOnlyThePaddleGeoReasonCarriesChecks() {
        for kind in BanditReasonKind.allCases where kind != .paddleGeo {
            XCTAssertTrue(mapper.map(kind).checks.isEmpty, "\(kind)")
        }
    }

    func testPaddleGeoChecksReflectTheDeviceSignals() {
        let checks = mapper.map(
            .paddleGeo,
            countrySignals: CountrySignals(deviceRegion: "US", storeCountry: "GB")
        ).checks

        XCTAssertEqual(checks, [
            DiagnosticCheck(label: "Device region is US", verdict: .passed),
            DiagnosticCheck(label: "App Store country is US", verdict: .failed),
            DiagnosticCheck(label: "IP country is US", verdict: .checkedByServer),
        ])
    }

    func testPaddleGeoChecksTreatMissingSignalsAsFailed() {
        let checks = mapper.map(.paddleGeo, countrySignals: CountrySignals()).checks

        XCTAssertEqual(checks[0].verdict, .failed)
        XCTAssertEqual(checks[1].verdict, .failed)
        XCTAssertEqual(checks[2].verdict, .checkedByServer)
    }

    func testPaddleGeoChecksIgnoreCountryCodeCase() {
        let checks = mapper.map(
            .paddleGeo,
            countrySignals: CountrySignals(deviceRegion: "us", storeCountry: "Us")
        ).checks

        XCTAssertEqual(checks[0].verdict, .passed)
        XCTAssertEqual(checks[1].verdict, .passed)
    }

    func testTheIpCountryRowIsAlwaysLeftToTheServer() {
        let checks = mapper.map(
            .paddleGeo,
            countrySignals: CountrySignals(deviceRegion: "US", storeCountry: "US")
        ).checks

        XCTAssertEqual(checks.last, DiagnosticCheck(label: "IP country is US", verdict: .checkedByServer))
    }
}
