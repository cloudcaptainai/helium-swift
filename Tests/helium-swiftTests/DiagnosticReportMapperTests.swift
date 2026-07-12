import XCTest
@testable import Helium

final class DiagnosticReportMapperTests: XCTestCase {

    private let contentMapper = DiagnosticContentMapper()
    private let mapper = DiagnosticReportMapper()

    /// The format is shared verbatim with the Android SDK so support tooling can parse either.
    func testReportMatchesTheCrossPlatformFormat() {
        let content = contentMapper.mapUnavailable(
            .webviewRenderFail,
            context: DiagnosticContext(trigger: "onboarding_end")
        )

        XCTAssertEqual(
            mapper.map(content, trigger: "onboarding_end", sdkVersion: "1.2.3"),
            """
            Helium paywall diagnostic
            trigger: onboarding_end
            reason: webviewRenderFail (integrationError)
            sdk: helium-swift 1.2.3
            The paywall failed to render — The paywall's web view failed to render, or could not communicate with the SDK. Retry once; if it reproduces, copy the diagnostic report and contact Helium.
            """
        )
    }

    func testReportNamesTheNetworkCategory() {
        let content = contentMapper.mapUnavailable(
            .paywallsDownloadFail,
            context: DiagnosticContext(trigger: "checkout")
        )

        XCTAssertEqual(
            mapper.map(content, trigger: "checkout", sdkVersion: "9.9.9"),
            """
            Helium paywall diagnostic
            trigger: checkout
            reason: paywallsDownloadFail (network)
            sdk: helium-swift 9.9.9
            Paywalls failed to download — Paywalls failed to download. Check this device's connection and your Helium API key.
            """
        )
    }
}
