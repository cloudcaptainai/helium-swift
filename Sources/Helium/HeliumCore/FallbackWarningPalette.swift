import SwiftUI

/// The amber palette every fallback-warning surface is drawn with, so that each surface telling a
/// developer a fallback paywall is on screen reads as one signal rather than several unrelated ones.
enum FallbackWarningPalette {

    static func background(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 122/255, green: 79/255, blue: 1/255)
            : Color(red: 255/255, green: 202/255, blue: 40/255)
    }

    static func text(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 255/255, green: 231/255, blue: 166/255)
            : Color(red: 74/255, green: 47/255, blue: 0/255)
    }

    /// Derived from the text color so the border stays visible against both scheme backgrounds.
    static func stroke(_ colorScheme: ColorScheme) -> Color {
        text(colorScheme).opacity(strokeOpacity)
    }

    private static let strokeOpacity: Double = 0.2
}
