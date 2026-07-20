//
//  DiagnosticCategoryStyle.swift
//  Helium
//

import SwiftUI
import UIKit

/// Presentation resources for a `DiagnosticCategory`'s banner strip.
///
/// The colors are dynamic: each resolves its light or dark variant from the trait collection at
/// render time, so no view has to branch on `colorScheme`.
struct DiagnosticCategoryStyle {
    let systemImageName: String
    let background: Color
    let foreground: Color

    init(systemImageName: String, light: RGB, dark: RGB, lightText: RGB, darkText: RGB) {
        self.systemImageName = systemImageName
        self.background = RGB.dynamicColor(light: light, dark: dark)
        self.foreground = RGB.dynamicColor(light: lightText, dark: darkText)
    }
}

/// A literal 8-bit color, so the palette in `DiagnosticCategoryStyleMapper` reads as the hex values
/// the cross-platform spec defines.
struct RGB {
    let r: Int
    let g: Int
    let b: Int

    var uiColor: UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// Resolves a light/dark pair from the trait collection at render time, so no view has to
    /// branch on `colorScheme`.
    static func dynamicColor(light: RGB, dark: RGB) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark.uiColor : light.uiColor })
    }
}
