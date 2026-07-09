import SwiftUI

/// A small amber pill overlaid on a Helium fallback paywall, so a developer can tell at a glance
/// that the live remote paywall was not the one that rendered.
///
/// Shown from DEBUG builds only. The SDK ships as source rather than a binary, so `#if DEBUG`
/// resolves against the host app's build configuration and this never reaches a TestFlight or
/// App Store build.
///
/// The pill is a passive indicator: it disables hit testing so every touch reaches the paywall
/// beneath it and it can never swallow a purchase tap.
struct FallbackDebugBadge: View {

    @Environment(\.colorScheme) private var colorScheme

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 122/255, green: 79/255, blue: 1/255)
            : Color(red: 255/255, green: 202/255, blue: 40/255)
    }

    private var textColor: Color {
        colorScheme == .dark
            ? Color(red: 255/255, green: 231/255, blue: 166/255)
            : Color(red: 74/255, green: 47/255, blue: 0/255)
    }

    var body: some View {
        Text("⚠ Fallback")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(textColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(backgroundColor))
            .overlay(
                Capsule().strokeBorder(Color.black.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.25), radius: 2, y: 1)
            .allowsHitTesting(false)
            .accessibilityLabel("Helium debug: fallback paywall")
    }
}

extension FallbackDebugBadge {

    /// A non-nil reason means Helium resolved a fallback bundle in place of the live remote
    /// paywall, which is exactly what the badge reports.
    static func shouldShow(fallbackReason: PaywallUnavailableReason?) -> Bool {
        return fallbackReason != nil
    }
}
