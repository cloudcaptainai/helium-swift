//
//  DiagnosticCategoryStyleMapper.swift
//  Helium
//

import Foundation

/// Maps a diagnostic category onto the banner resources that render it.
///
/// Icons are per category, but tints are per severity: `.setup` and `.network` are different
/// categories at the same (warning) severity, so they share the amber pair while keeping distinct
/// icons.
struct DiagnosticCategoryStyleMapper {

    private enum Palette {
        static let infoBackgroundLight = RGB(r: 220, g: 235, b: 255)
        static let infoTextLight = RGB(r: 10, g: 61, b: 122)
        static let infoBackgroundDark = RGB(r: 18, g: 58, b: 102)
        static let infoTextDark = RGB(r: 207, g: 227, b: 255)

        static let warningBackgroundLight = RGB(r: 255, g: 202, b: 40)
        static let warningTextLight = RGB(r: 74, g: 47, b: 0)
        static let warningBackgroundDark = RGB(r: 122, g: 79, b: 1)
        static let warningTextDark = RGB(r: 255, g: 231, b: 166)

        static let errorBackgroundLight = RGB(r: 255, g: 217, b: 214)
        static let errorTextLight = RGB(r: 122, g: 20, b: 20)
        static let errorBackgroundDark = RGB(r: 102, g: 20, b: 20)
        static let errorTextDark = RGB(r: 255, g: 208, b: 204)
    }

    func map(_ category: DiagnosticCategory) -> DiagnosticCategoryStyle {
        switch category {
        case .expected:
            return DiagnosticCategoryStyle(
                systemImageName: "info.circle.fill",
                light: Palette.infoBackgroundLight,
                dark: Palette.infoBackgroundDark,
                lightText: Palette.infoTextLight,
                darkText: Palette.infoTextDark
            )
        case .setup:
            return DiagnosticCategoryStyle(
                systemImageName: "exclamationmark.triangle.fill",
                light: Palette.warningBackgroundLight,
                dark: Palette.warningBackgroundDark,
                lightText: Palette.warningTextLight,
                darkText: Palette.warningTextDark
            )
        case .network:
            return DiagnosticCategoryStyle(
                systemImageName: "wifi.exclamationmark",
                light: Palette.warningBackgroundLight,
                dark: Palette.warningBackgroundDark,
                lightText: Palette.warningTextLight,
                darkText: Palette.warningTextDark
            )
        case .integrationError:
            return DiagnosticCategoryStyle(
                systemImageName: "xmark.octagon.fill",
                light: Palette.errorBackgroundLight,
                dark: Palette.errorBackgroundDark,
                lightText: Palette.errorTextLight,
                darkText: Palette.errorTextDark
            )
        }
    }
}
