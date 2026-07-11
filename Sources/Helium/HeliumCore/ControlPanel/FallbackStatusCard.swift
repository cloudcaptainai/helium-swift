import SwiftUI

/// Amber card telling a developer that the paywall behind the control panel is a fallback and
/// which bundle entry served it.
struct FallbackStatusCard: View {

    @Environment(\.colorScheme) private var colorScheme

    let status: FallbackStatusContext

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(FallbackStatusContext.disclaimer)
                .font(.subheadline.weight(.bold))
                .padding(.bottom, 4)

            Text(status.reasonLine)
            Text(status.requestedTriggerLine)
            Text(status.resolvedEntryLine)
            Text(status.servingPaywallLine)
            Text(status.configuredBundleLine)
        }
        .font(.footnote)
        .foregroundColor(FallbackWarningPalette.text(colorScheme))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FallbackWarningPalette.background(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(FallbackWarningPalette.stroke(colorScheme), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
