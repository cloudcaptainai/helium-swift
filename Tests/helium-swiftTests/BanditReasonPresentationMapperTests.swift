import XCTest
@testable import Helium

final class BanditReasonPresentationMapperTests: XCTestCase {
    private let mapper = BanditReasonPresentationMapper()
    static let paddleGeoSentence = "Server wording may change."

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
