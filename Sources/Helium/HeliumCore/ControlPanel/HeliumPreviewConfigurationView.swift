//
//  HeliumPreviewConfigurationView.swift
//  Helium
//
//  Settings sheet shown before a paywall preview opens, so a tester picks the checkout behaviour
//  they want before the paywall is on screen rather than discovering it mid-flow.
//

import SwiftUI

struct HeliumPreviewConfigurationView: View {
    let request: HeliumPreviewConfigurationRequest
    let onStart: (HeliumPreviewConfiguration) -> Void
    let onCancel: () -> Void

    @State private var configuration = HeliumPreviewConfiguration.lastUsed

    /// Prototype knob: flip to preview how the sheet reads for a tester outside the US, where real
    /// Paddle checkout is unavailable.
    private let simulatesNonUSDevice = false

    private var realPurchaseUnavailable: Bool { simulatesNonUSDevice }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                bannerStrip

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        title
                        paywallPill
                        purchaseSection
                        complianceSection
                        contextSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 20)
                }

                actionBar
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }

    /// Pinned under the scrolling settings.
    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 0) {
                startAction
                cancelAction
                footer
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 6)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Header

    private var bannerStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.body)
            Text("PREVIEW CONFIGURATION")
                .font(.subheadline.weight(.bold))
                .kerning(0.8)
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
            }
            .accessibilityLabel("Cancel")
        }
        .foregroundColor(accentForeground)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(accentBackground)
    }

    private var title: some View {
        Text(request.paywallName)
            .font(.title2.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var paywallPill: some View {
        HStack(spacing: 8) {
            if let versionLabel = request.versionLabel {
                pill(versionLabel)
            }
            if request.isWebPaywall {
                pill("Web paywall")
            }
            pill("app2web")
        }
        .padding(.top, 10)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(accentForeground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(accentBackground))
    }

    // MARK: - Purchase flow

    private var purchaseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("PURCHASE FLOW")
            ForEach(HeliumPreviewPurchaseMode.allCases) { mode in
                purchaseOption(mode)
            }
        }
        .padding(.top, 22)
    }

    private func purchaseOption(_ mode: HeliumPreviewPurchaseMode) -> some View {
        let isDisabled = mode.isUSOnly && realPurchaseUnavailable
        let isSelected = configuration.purchaseMode == mode && !isDisabled

        return Button {
            guard !isDisabled else { return }
            configuration.purchaseMode = mode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .blue : .secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: mode.systemImageName)
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.secondary)
                        Text(mode.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        if mode == .simulated {
                            tag("DEFAULT")
                        }
                        if mode.isUSOnly {
                            tag("US ONLY")
                        }
                    }
                    Text(mode.detail)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    if isDisabled {
                        Label("Region outside the US. Use simulated, or a US VPN.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? selectedBackground : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue : Color(.separator), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.55 : 1)
    }

    // MARK: - Compliance

    private var complianceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("COMPLIANCE")

            Toggle(isOn: $configuration.showCaliforniaConsentModal) {
                Text("Show California consent modal")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
            }
            .toggleStyle(SwitchToggleStyle(tint: .blue))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(.separator), lineWidth: 1)
            )
        }
        .padding(.top, 22)
    }

    // MARK: - Paywall context

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("PAYWALL CONTEXT")

            VStack(spacing: 0) {
                NavigationLink {
                    HeliumPreviewKeyValueEditor(
                        title: "Paywall Traits",
                        explanation: "Trait values the paywall renders with for this run. Anything you leave out keeps the value the paywall was published with.",
                        keyPlaceholder: "Trait name",
                        entries: $configuration.traits
                    )
                } label: {
                    contextRow("Paywall traits", value: configuration.traitsSummary, icon: "square.stack.3d.up")
                }

                Divider().padding(.leading, 44)

                NavigationLink {
                    HeliumPreviewLanguageEditor(language: $configuration.language)
                } label: {
                    contextRow("Language", value: configuration.language.summary, icon: "globe")
                }

                Divider().padding(.leading, 44)

                NavigationLink {
                    HeliumPreviewKeyValueEditor(
                        title: "User Attributes",
                        explanation: "Custom user attributes for this run, so you can stand in as a targeted user without changing the account you are signed in as.",
                        keyPlaceholder: "Attribute name",
                        entries: $configuration.userAttributes
                    )
                } label: {
                    contextRow("Custom user attributes", value: configuration.userAttributesSummary, icon: "person.crop.circle")
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(.separator), lineWidth: 1)
            )
        }
        .padding(.top, 22)
    }

    private func contextRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private var startAction: some View {
        Button {
            HeliumPreviewConfiguration.lastUsed = configuration
            onStart(configuration)
        } label: {
            Text(configuration.purchaseMode == .real ? "Start Real Purchase Preview" : "Start Simulated Preview")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
        }
    }

    private var cancelAction: some View {
        Button(action: onCancel) {
            Text("Cancel")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .padding(.top, 4)
    }

    private var footer: some View {
        Text("Non-production · helium_testing · \(HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER)")
            .font(.caption2.monospaced())
            .foregroundColor(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
    }

    // MARK: - Pieces

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .kerning(0.8)
            .foregroundColor(.secondary)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .kerning(0.5)
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(UIColor.tertiarySystemFill)))
    }

    // MARK: - Colors

    private var accentForeground: Color {
        RGB.dynamicColor(light: RGB(r: 44, g: 112, b: 106), dark: RGB(r: 127, g: 216, b: 201))
    }

    private var accentBackground: Color {
        RGB.dynamicColor(light: RGB(r: 213, g: 248, b: 239), dark: RGB(r: 18, g: 59, b: 53))
    }

    private var selectedBackground: Color {
        RGB.dynamicColor(light: RGB(r: 233, g: 241, b: 255), dark: RGB(r: 22, g: 38, b: 66))
    }
}
