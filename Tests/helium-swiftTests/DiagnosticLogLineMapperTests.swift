import XCTest
@testable import Helium

final class DiagnosticLogLineMapperTests: XCTestCase {

    private let contentMapper = DiagnosticContentMapper()
    private let mapper = DiagnosticLogLineMapper()

    private func logLine(for reason: PaywallUnavailableReason) -> String {
        let content = contentMapper.mapUnavailable(
            reason,
            context: DiagnosticContext(trigger: "onboarding_end")
        )
        return mapper.map(content)
    }

    func testUrlCtaCarriesTheReasonCodeAndTheUrl() {
        let line = logLine(for: .triggerHasNoPaywall)

        XCTAssertTrue(line.hasPrefix("[triggerHasNoPaywall] "))
        XCTAssertTrue(line.contains("No paywall is connected to this trigger."))
        XCTAssertTrue(line.hasSuffix("https://app.tryhelium.com/workflows"))
    }

    /// A copy-report reason has no CTA destination, so the line carries the remediation link.
    func testCopyReportCtaAppendsTheRemediationUrl() {
        let line = logLine(for: .webviewRenderFail)

        XCTAssertTrue(line.hasPrefix("[webviewRenderFail] The paywall failed to render."))
        XCTAssertTrue(line.hasSuffix("https://docs.tryhelium.com/guides/fallback-bundle"))
    }

    /// One URL per line keeps every line the same shape for grep-based workflows.
    func testNoLineCarriesMoreThanOneUrl() {
        for reason in PaywallUnavailableReason.allCases {
            let urls = logLine(for: reason).components(separatedBy: "http").count - 1
            XCTAssertLessThanOrEqual(urls, 1, reason.rawValue)
        }
    }

    /// Existing grep-based log workflows key off this wording.
    func testAlreadyPresentedKeepsItsExistingWording() {
        XCTAssertTrue(
            logLine(for: .alreadyPresented).contains("A Helium paywall is already being presented")
        )
    }

    func testEveryReasonLeadsWithItsBracketedReasonCode() {
        for reason in PaywallUnavailableReason.allCases {
            XCTAssertTrue(
                logLine(for: reason).hasPrefix("[\(reason.rawValue)] "),
                reason.rawValue
            )
        }
    }
}
