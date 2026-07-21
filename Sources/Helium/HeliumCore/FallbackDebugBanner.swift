import SwiftUI

/// A banner spanning the top edge of a Helium fallback paywall, so a developer can tell at a glance
/// that the live remote paywall was not the one that rendered.
///
/// Shown from DEBUG builds only. The SDK ships as source rather than a binary, so `#if DEBUG`
/// resolves against the host app's build configuration and this never reaches a TestFlight or
/// App Store build.
///
/// It spans the width so it reads as a notification rather than a chip. That is a deliberate trade:
/// the card is interactive, so at full width it covers the top corners where paywalls place their
/// close button, and swallows those taps. Dismissing is the way out, so the paywall's own close
/// button is never more than one extra tap away.
struct FallbackDebugBanner: View {

    let trigger: String
    let fallbackReason: PaywallUnavailableReason?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresented = false

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 18/255, green: 58/255, blue: 102/255)
            : Color(red: 220/255, green: 235/255, blue: 255/255)
    }

    private var foregroundColor: Color {
        colorScheme == .dark
            ? Color(red: 207/255, green: 227/255, blue: 255/255)
            : Color(red: 10/255, green: 61/255, blue: 122/255)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    var body: some View {
        // The banner animates itself in and out, so it needs a container that outlives its own
        // visibility. An empty ZStack lays out at zero size, leaving the paywall untouched.
        ZStack {
            if isPresented {
                banner.transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) {
                isPresented = true
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Fallback Paywall")
                    .font(.system(size: 15, weight: .semibold))
                Text("Tap for details")
                    .font(.system(size: 12, weight: .regular))
                    .opacity(0.9)
            }
            // Taking the slack is what pins the dismiss control to the trailing edge.
            .frame(maxWidth: .infinity, alignment: .leading)
            dismissButton
                .padding(.leading, 2)
        }
        .foregroundColor(foregroundColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(shape.fill(backgroundColor))
        // A soft rim keeps the card legible on a paywall of any colour.
        .overlay(shape.strokeBorder(Color.black.opacity(0.2), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.22), radius: 8, y: 3)
        .contentShape(shape)
        // The nested dismiss Button resolves first within its own bounds, so this only catches
        // taps on the rest of the card.
        .onTapGesture { openDiagnostics() }
        .accessibilityAction(named: "Show diagnostics") { openDiagnostics() }
    }

    /// The diagnostic view keeps its own gating, so a tap is silently ignored when the developer
    /// has turned diagnostics off or ticked "do not show again".
    private func openDiagnostics() {
        guard !trigger.isEmpty else { return }
        let message = PaywallDiagnosticMessages.remediationMessage(
            for: fallbackReason,
            trigger: trigger
        )
        Task { @MainActor in
            HeliumPaywallDiagnosticView.presentIfNeeded(trigger: trigger, message: message)
        }
    }

    private var dismissButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .opacity(0.85)
                // Touch area rather than decoration: it grows the target past the glyph.
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }

    private func dismiss() {
        withAnimation(.easeIn(duration: 0.2)) {
            isPresented = false
        }
    }
}

extension FallbackDebugBanner {

    /// A non-nil reason means Helium resolved a fallback bundle in place of the live remote
    /// paywall, which is exactly what the banner reports.
    static func shouldShow(fallbackReason: PaywallUnavailableReason?) -> Bool {
        return fallbackReason != nil
    }
}
