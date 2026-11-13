import XCTest
@testable import Helium

final class BanditReasonPresentationMapperTests: XCTestCase {
    private let mapper = BanditReasonPresentationMapper()
    static let paddleGeoSentence = "Server wording may change."

    private static let expected: [String: (title: String, fix: String)] = [
        "paddle_ip_country_not_us": ("Paddle needs a US buyer", "Target this paywall at a US audience, or add a rule for users outside the US."),
        "paddle_store_country_not_us": ("Paddle needs a US buyer", "Target this paywall at a US audience, or add a rule for users outside the US."),
        "paddle_locale_country_not_us": ("Paddle needs a US buyer", "Target this paywall at a US audience, or add a rule for users outside the US."),
        "paddle_country_unverified": ("Paddle needs a US buyer", "Target this paywall at a US audience, or add a rule for users outside the US."),
        "paddle_ca_consent_required": ("California needs the consent modal", "Update the SDK and enable the consent modal for this org."),
        "paddle_credentials_unusable": ("Paddle credentials missing", "Reconnect Paddle under Integrations, then publish the paywall again."),
        "paddle_sandbox_price_not_copied": ("Paddle sandbox products not synced", "Open the Helium dashboard and sync Paddle sandbox products."),
        "paddle_sandbox_copies_unavailable": ("Paddle sandbox products not synced", "Open the Helium dashboard and sync Paddle sandbox products."),
        "paddle_sandbox_credentials_unreadable": ("Paddle sandbox account unreadable", "Reconnect the Paddle sandbox account under Integrations."),
        "paddle_android_unsupported": ("Paddle checkout not supported on Android", "Add a rule for Android users or use Play products."),
        "stripe_android_unsupported": ("Stripe checkout not supported on Android", "Add a rule for Android users or use Play products."),
        "stripe_external_apple_pay_unavailable": ("Apple Pay not available", "Test on a device with a card in Wallet, or add a rule for users without Apple Pay."),
        "stripe_in_app_apple_pay_unavailable": ("Apple Pay not available for in-app Stripe", "Test on a device with a card in Wallet, or add a rule for users without Apple Pay."),
        "paywall_not_found": ("Paywall not found", "Reconnect the workflow to an existing paywall."),
        "paywall_version_unresolved": ("Paywall version not published", "Open the paywall in the editor and publish it."),
        "no_targeting_match": ("No targeting rule matched", "Add a rule for everyone else, or set a default paywall on the workflow."),
        "targeting_no_paywall": ("Rule shows no paywall", "This rule is configured to show nothing; change it or add a paywall."),
        "targeting_misconfigured": ("Targeting rule misconfigured", "Give the rule a paywall or experiment."),
        "targeting_parse_error": ("Targeting rules unreadable", "Copy the diagnostic report and contact Helium."),
        "workflow_no_paywall": ("Workflow has no default paywall", "Set a default paywall or experiment on the workflow."),
        "experiment_unresolved": ("Experiment stopped or missing", "Reconnect the workflow to a live experiment."),
        "experiment_misconfigured": ("Experiment misconfigured", "Open the experiment and fix its allocation, then take it live again."),
        "experiment_not_exposed": ("User outside experiment exposure", "This is expected; raise exposure or add a default paywall."),
        "no_workflow_connected": ("No workflow on this trigger", "Add the trigger to a workflow in the dashboard."),
        "workflow_not_found": ("Workflow not found", "Reconnect the trigger to an existing workflow."),
    ]

    func testEachServerCodeHasItsAuthoredTitleAndFix() {
        XCTAssertEqual(Set(BanditReasonPresentationMapper.presentations.keys), Set(Self.expected.keys))
        for (code, expected) in Self.expected {
            let actual = mapper.map(code)
            XCTAssertEqual(actual.title, expected.title, code)
            XCTAssertEqual(actual.fix, expected.fix, code)
        }
    }

    func testEveryKnownCodeHasAPresentation() {
        XCTAssertEqual(BanditReasonPresentationMapper.presentations.count, 25)
        for (code, expected) in BanditReasonPresentationMapper.presentations {
            let actual = mapper.map(code)
            XCTAssertEqual(actual.title, expected.title, code)
            XCTAssertEqual(actual.fix, expected.fix, code)
            XCTAssertNotEqual(actual, .unrecognised, code)
            XCTAssertFalse(actual.title.isEmpty, code)
            XCTAssertFalse(actual.fix?.isEmpty ?? true, code)
            XCTAssertFalse(actual.title.lowercased().contains("fallback"), code)
            XCTAssertFalse(actual.fix?.lowercased().contains("fallback") ?? true, code)
        }
    }

    func testMatchingTrimsAndIgnoresCase() {
        XCTAssertEqual(mapper.map(" \nNO_WORKFLOW_CONNECTED "), mapper.map("no_workflow_connected"))
    }

    func testUnknownEmptyAndMissingCodesAreUnrecognised() {
        for code in ["new_server_code", "", "  ", "workflow_error", Self.paddleGeoSentence] {
            XCTAssertEqual(mapper.map(code), .unrecognised)
        }
        XCTAssertEqual(mapper.map(nil), .unrecognised)
    }

    func testGeoCodeDeterminesTheFailedRowRegardlessOfLocalSignals() {
        let codes = ["paddle_locale_country_not_us", "paddle_store_country_not_us", "paddle_ip_country_not_us"]
        for (failedRow, code) in codes.enumerated() {
            for signals in [CountrySignals(), CountrySignals(deviceRegion: "US", storeCountry: "US"),
                            CountrySignals(deviceRegion: "GB", storeCountry: "CA")] {
                let checks = mapper.map(code, countrySignals: signals).checks
                XCTAssertEqual(checks.count, 3)
                for (index, check) in checks.enumerated() {
                    XCTAssertEqual(check.verdict, index == failedRow ? .failed : .unknown)
                }
            }
        }
    }

    func testUnverifiedCountryLeavesAllRowsUnknownAndExplainsMissingSignal() {
        let checks = mapper.map("paddle_country_unverified").checks
        XCTAssertEqual(checks.map(\.verdict), [.unknown, .unknown, .unknown])
        XCTAssertTrue(checks.last?.label.contains("a signal was missing") == true)
    }

    func testLocalCountryValuesRemainVisible() {
        let checks = mapper.map("paddle_ip_country_not_us", countrySignals: CountrySignals(deviceRegion: "GB", storeCountry: "US")).checks
        XCTAssertTrue(checks[0].label.contains("GB"))
        XCTAssertTrue(checks[1].label.contains("US"))
    }

    func testOnlyGeoCodesHaveChecks() {
        for code in BanditReasonPresentationMapper.presentations.keys {
            XCTAssertEqual(mapper.map(code).checks.isEmpty,
                           !["paddle_ip_country_not_us", "paddle_store_country_not_us", "paddle_locale_country_not_us", "paddle_country_unverified"].contains(code))
        }
    }
}
