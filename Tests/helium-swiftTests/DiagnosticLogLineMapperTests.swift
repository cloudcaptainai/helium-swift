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

    func testCopyReportCtaAppendsNoUrl() {
        let line = logLine(for: .webviewRenderFail)

        XCTAssertTrue(line.hasPrefix("[webviewRenderFail] The paywall failed to render."))
        XCTAssertFalse(line.contains("http"))
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
