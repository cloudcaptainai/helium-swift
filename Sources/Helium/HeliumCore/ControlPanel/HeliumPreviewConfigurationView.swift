//
//  HeliumPreviewConfigurationView.swift
//  Helium
//
//  App2web preview settings. Opened from the previews list to edit the session settings,
//  or — when "configure before each preview" is on — ahead of an app2web paywall launch.
//

import SwiftUI

struct HeliumPreviewConfigurationView: View {
    let request: HeliumPreviewConfigurationRequest
    let onStart: (HeliumPreviewConfiguration) -> Void
    let onCancel: () -> Void

    @ObservedObject private var store = HeliumPreviewConfigurationStore.shared
    @State private var configuration = HeliumPreviewConfigurationStore.shared.configuration

    private var realPurchaseUnavailable: Bool { store.forceExternalCheckoutSimulation }

    var body: some View {
        VStack(spacing: 0) {
            bannerStrip

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    title
                    subheader
                    purchaseSection
                    if request.showsCompliance {
                        complianceSection
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 20)
            }

            actionBar
        }
    }

    /// Pinned under the scrolling settings.
    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 0) {
                startAction
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 10)
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
        Text(request.title)
            .font(.title2.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var subheader: some View {
        if request.isSettings {
            Text("Configure the paywall preview experience for your Paddle and Stripe app2web paywalls.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        } else if let versionLabel = request.versionLabel {
            HStack(spacing: 8) {
                pill(versionLabel)
            }
            .padding(.top, 10)
        }
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
                        Label("Region outside the US. Use simulated or a US VPN.", systemImage: "exclamationmark.triangle.fill")
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

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $configuration.showCaliforniaConsentModal) {
                    Text("Show California consent modal")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                }
                .toggleStyle(SwitchToggleStyle(tint: .blue))
                Text("Paddle checkouts only. Real purchases from California always show the modal.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    // MARK: - Actions

    private var startActionLabel: String {
        if request.isSettings {
            return "Save Settings"
        }
        return configuration.purchaseMode == .real ? "Start Real Purchase Preview" : "Start Simulated Preview"
    }

    private var startAction: some View {
        Button {
            store.configuration = configuration
            onStart(configuration)
        } label: {
            Text(startActionLabel)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
        }
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
