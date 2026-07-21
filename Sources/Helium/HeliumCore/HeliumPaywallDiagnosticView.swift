//
//  HeliumPaywallDiagnosticView.swift
//  Helium
//
//  Diagnostic modal shown when a paywall fails to display or is skipped.
//
//  All displayed copy arrives as an authored `DiagnosticContent`, so nothing here has to infer
//  meaning — or a CTA destination — from message text.
//

import SwiftUI
import UIKit

// MARK: - SwiftUI View

struct HeliumPaywallDiagnosticView: View {
    let content: DiagnosticContent
    let triggerName: String
    let onDismiss: () -> Void

    @State private var doNotShowAgain: Bool = UserDefaults.standard.bool(forKey: "heliumDiagnosticDoNotShowAgain")

    private let styleMapper = DiagnosticCategoryStyleMapper()
    private let reportMapper = DiagnosticReportMapper()

    private var style: DiagnosticCategoryStyle {
        styleMapper.map(content.category)
    }

    private var report: String {
        reportMapper.map(content, trigger: triggerName, sdkVersion: BuildConstants.version)
    }

    private var isForPreview: Bool {
        triggerName == HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                bannerStrip

                VStack(alignment: .leading, spacing: 0) {
                    overline
                    title
                    if !isForPreview {
                        triggerPill
                    }
                    bodyText
                    usersCallout
                    primaryAction
                    secondaryAction
                    if !isForPreview {
                        doNotShowAgainToggle
                    }
                    footer
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 30)
            }
        }
    }

    // MARK: - Elements

    /// Full-width tinted row. The modal is classifiable before a single word of prose is read.
    private var bannerStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: style.systemImageName)
                .font(.body)
            Text(content.category.bannerLabel)
                .font(.subheadline.weight(.bold))
                .kerning(0.8)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
            }
            .accessibilityLabel("Dismiss")
        }
        .foregroundColor(style.foreground)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(style.background)
    }

    /// Branding demotes so the diagnosis can promote.
    private var overline: some View {
        Text("HELIUM PAYWALL DIAGNOSTIC")
            .font(.caption2.weight(.bold))
            .kerning(1)
            .foregroundColor(.secondary)
    }

    private var title: some View {
        Text(content.title)
            .font(.title.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
    }

    private var triggerPill: some View {
        Button(action: { UIPasteboard.general.string = triggerName }) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trigger")
                    .font(.subheadline)
                Text(triggerName)
                    .font(.title3.weight(.semibold))
                Text("(tap to copy)")
                    .font(.caption2)
                    .opacity(0.7)
            }
            .foregroundColor(triggerTextColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(triggerBackgroundColor)
            .cornerRadius(12)
        }
        .padding(.top, 20)
    }

    private var bodyText: some View {
        Text(content.body)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
    }

    /// A distinct element rather than body prose: it answers the tester's actual question — did real
    /// customers get a broken experience?
    private var usersCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT REAL USERS SEE")
                .font(.caption2.weight(.bold))
                .kerning(0.8)
                .foregroundColor(.secondary)
            Text(content.usersWillSee)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            usersCalloutLink
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.separator), lineWidth: 1)
        )
        .padding(.top, 20)
    }

    /// A `Button` rather than a `Link` so an unparseable URL still renders the remediation, inert,
    /// instead of dropping it from the callout entirely. Tinted with the modal's own blue rather
    /// than the host app's accent, which is arbitrary and can land illegibly on this background.
    @ViewBuilder
    private var usersCalloutLink: some View {
        if let link = content.usersWillSeeLink {
            Button(action: { open(link.url) }) {
                Text(link.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.blue)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .accessibilityAddTraits(.isLink)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch content.cta {
        case let .openUrl(label, urlString):
            HStack(spacing: 12) {
                filledCtaButton(label) { open(urlString) }
                Button(action: { UIPasteboard.general.string = urlString }) {
                    Image(systemName: "doc.on.doc")
                        .font(.body)
                        .padding(14)
                        .background(Color(.systemGray5))
                        .cornerRadius(12)
                }
                .accessibilityLabel("Copy URL")
            }
            .padding(.top, 24)

        // The report is the only action worth offering — no support URL is invented for it.
        case .copyReport:
            filledCtaButton("Copy Diagnostic Report", action: copyReport)
                .padding(.top, 24)
        }
    }

    /// Hidden when copying the report is already the primary CTA.
    @ViewBuilder
    private var secondaryAction: some View {
        if case .openUrl = content.cta {
            Button(action: copyReport) {
                Text("Copy Diagnostic Report")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .padding(.top, 4)
        }
    }

    private func filledCtaButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
        }
    }

    private func copyReport() {
        UIPasteboard.general.string = report
    }

    private var doNotShowAgainToggle: some View {
        Toggle(isOn: $doNotShowAgain) {
            Text("Do not show again on this device")
                .font(.subheadline)
        }
        .toggleStyle(CheckboxToggleStyle())
        .onChange(of: doNotShowAgain) { newValue in
            UserDefaults.standard.set(newValue, forKey: "heliumDiagnosticDoNotShowAgain")
        }
        .padding(.top, 20)
    }

    /// The visibility disclaimer is only true on the non-preview path: dashboard previews bypass
    /// the display flag, so the claim may not render there.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isForPreview {
                Text("This diagnostic view is only shown in DEBUG builds.\n\nYou can disable it by setting Helium.config.paywallNotShownDiagnosticDisplayEnabled to false.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Text("Reason code: \(content.reasonCode)")
                .font(.caption2.monospaced())
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 28)
    }

    // MARK: - Colors

    private var triggerTextColor: Color {
        RGB.dynamicColor(light: RGB(r: 44, g: 112, b: 106), dark: RGB(r: 127, g: 216, b: 201))
    }

    private var triggerBackgroundColor: Color {
        RGB.dynamicColor(light: RGB(r: 213, g: 248, b: 239), dark: RGB(r: 18, g: 59, b: 53))
    }

    /// An unopenable link is not worth crashing or trapping over — the copy-URL affordance beside
    /// the CTA still gets the developer where they are going.
    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Checkbox Toggle Style

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .foregroundColor(configuration.isOn ? .blue : .secondary)
                .font(.system(size: 20))
            configuration.label
        }
        .onTapGesture {
            configuration.isOn.toggle()
        }
    }
}

// MARK: - Presentation

extension HeliumPaywallDiagnosticView {

    private static var isCurrentlyPresented = false
    private static weak var presentedController: UIViewController?
    private static var diagnosticWindow: UIWindow?

    /// Dismisses the diagnostic view if it is currently presented.
    @MainActor
    static func dismissIfPresented() {
        guard isCurrentlyPresented, let controller = presentedController else { return }
        controller.dismiss(animated: false)
        tearDown()
    }

    private static func tearDown() {
        isCurrentlyPresented = false
        presentedController = nil
        diagnosticWindow?.isHidden = true
        diagnosticWindow = nil
    }

    @MainActor
    static func presentIfNeeded(trigger: String, content: DiagnosticContent) {
        guard shouldPresent(trigger: trigger) else { return }
        present(content: content, triggerName: trigger)
    }

    @MainActor
    private static func shouldPresent(trigger: String) -> Bool {
        guard !isCurrentlyPresented else { return false }
        if trigger == HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER {
            return true
        }
        guard Helium.config.paywallNotShownDiagnosticDisplayEnabled else { return false }
        guard !UserDefaults.standard.bool(forKey: "heliumDiagnosticDoNotShowAgain") else { return false }
        return true
    }

    @MainActor
    private static func present(content: DiagnosticContent, triggerName: String) {
        guard let windowScene = UIWindowHelper.findActiveWindow()?.windowScene else { return }

        isCurrentlyPresented = true

        let diagnosticView = HeliumPaywallDiagnosticView(
            content: content,
            triggerName: triggerName,
            onDismiss: {
                presentedController?.dismiss(animated: true) {
                    tearDown()
                }
            }
        )

        let hostingController = UIHostingController(rootView: diagnosticView)
        hostingController.modalPresentationStyle = .fullScreen

        let window = UIWindow(windowScene: windowScene)
        let containerVC = UIViewController()
        window.rootViewController = containerVC
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()

        diagnosticWindow = window
        presentedController = hostingController

        containerVC.present(hostingController, animated: true)
    }
}
