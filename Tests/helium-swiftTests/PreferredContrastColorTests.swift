import XCTest
@testable import Helium

/// Pins where the black-or-white choice flips: white is kept while it holds 3:1, so mid-tones
/// that black technically out-contrasts still get white.
final class PreferredContrastColorTests: XCTestCase {

    private func rgb(_ red: Int, _ green: Int, _ blue: Int) -> UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    func testExtremes() {
        XCTAssertEqual(UIColor.black.preferredContrastColor, .white)
        XCTAssertEqual(UIColor.white.preferredContrastColor, .black)
    }

    /// System blue sits around 0.21 luminance: black has more contrast, but white still
    /// clears 3:1.
    func testMidToneWhereWhiteStillHoldsKeepsWhite() {
        XCTAssertEqual(rgb(0, 122, 255).preferredContrastColor, .white)
        XCTAssertEqual(rgb(128, 128, 128).preferredContrastColor, .white)
    }

    /// System orange sits around 0.43 luminance, where white falls to about 2.2:1.
    func testMidToneWhereWhiteFallsBelowThreeToOneSwitchesToBlack() {
        XCTAssertEqual(rgb(255, 149, 0).preferredContrastColor, .black)
    }

    func testSpinnerFollowsADynamicCoverColorPerAppearance() throws {
        let cover = InAppWebCheckoutLoadingCover.color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? .black : .white
        })
        let spinner = try XCTUnwrap(cover.spinnerColor)

        XCTAssertEqual(spinner.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)), .black)
        XCTAssertEqual(spinner.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)), .white)
    }
}
