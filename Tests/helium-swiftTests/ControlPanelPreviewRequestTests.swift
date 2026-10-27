import XCTest
@testable import Helium

final class ControlPanelPreviewRequestTests: XCTestCase {

    func testPreviewUserContextCarriesLocaleAndSdkIdentity() {
        let locale: [String: Any] = ["currentCountry": "US", "storeCountryCode": "USA"]

        let context = HeliumControlPanelService.previewUserContext(locale: locale)

        let sentLocale = context["locale"] as? [String: Any]
        XCTAssertEqual(sentLocale?["currentCountry"] as? String, "US")
        XCTAssertEqual(sentLocale?["storeCountryCode"] as? String, "USA")

        let appInfo = context["applicationInfo"] as? [String: Any]
        XCTAssertEqual(appInfo?["platform"] as? String, "ios")
        XCTAssertEqual(appInfo?["heliumSdkVersion"] as? String, BuildConstants.version)
        XCTAssertEqual(appInfo?["heliumSdk"] as? String, HeliumSdkConfig.shared.heliumSdk)
        XCTAssertEqual(appInfo?["heliumWrapperSdkVersion"] as? String, HeliumSdkConfig.shared.heliumWrapperSdkVersion)
        XCTAssertEqual(appInfo?["environment"] as? String, AppReceiptsHelper.shared.getEnvironment().uppercased())
        XCTAssertTrue(JSONSerialization.isValidJSONObject(context))
    }
}
