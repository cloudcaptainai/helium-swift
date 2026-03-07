//
//  HeliumPaywallDiagnosticView.swift
//  Helium
//
//  Debug-only diagnostic modal shown when a paywall fails to display or is skipped.
//

#if DEBUG
import SwiftUI
import UIKit

// MARK: - Data Model

struct DiagnosticContent {
    let bodyText: String
    let ctaTitle: String
    let ctaURL: URL

    // MARK: - Factory from PaywallUnavailableReason

    static func from(
        unavailableReason: PaywallUnavailableReason?,
        bodyText: String
    ) -> DiagnosticContent {
        guard let reason = unavailableReason else {
            return DiagnosticContent(
                bodyText: bodyText,
                ctaTitle: "View Docs",
                ctaURL: URL(string: "https://docs.tryhelium.com")!
            )
        }

        let (ctaTitle, ctaURL): (String, URL) = {
            switch reason {
            case .notInitialized:
                return ("View Quickstart Guide", URL(string: "https://docs.tryhelium.com/sdk/quickstart-ios")!)

            case .triggerHasNoPaywall:
                return ("Open Workflows", URL(string: "https://app.tryhelium.com/workflows")!)

            case .paywallsNotDownloaded, .configFetchInProgress, .bundlesFetchInProgress, .productsFetchInProgress:
                return ("Fallbacks Guide", URL(string: "https://docs.tryhelium.com/sdk/quickstart-ios#fallback-bundles")!)

            case .paywallsDownloadFail:
                return ("Fallbacks Guide", URL(string: "https://docs.tryhelium.com/sdk/quickstart-ios#fallback-bundles")!)

            case .paywallBundlesMissing:
                return ("Open Paywalls", URL(string: "https://app.tryhelium.com/paywalls")!)

            case .noProductsIOS:
                return ("Open Paywalls", URL(string: "https://app.tryhelium.com/paywalls")!)

            case .stripeNoCustomUserId:
                return ("View Quickstart Guide", URL(string: "https://docs.tryhelium.com/sdk/quickstart-ios")!)

            case .alreadyPresented:
                return ("View Docs", URL(string: "https://docs.tryhelium.com")!)

            case .noRootController:
                return ("View Docs", URL(string: "https://docs.tryhelium.com")!)

            case .couldNotFindBundleUrl, .bundleFetchInvalidUrlDetected, .bundleFetchInvalidUrl:
                return ("Open Paywalls", URL(string: "https://app.tryhelium.com/paywalls")!)

            case .bundleFetch403:
                return ("Open Settings", URL(string: "https://app.tryhelium.com/settings")!)

            case .bundleFetch404:
                return ("Open Paywalls", URL(string: "https://app.tryhelium.com/paywalls")!)

            case .bundleFetch410:
                return ("Open Paywalls", URL(string: "https://app.tryhelium.com/paywalls")!)

            case .bundleFetchCannotDecodeContent:
                return ("View Docs", URL(string: "https://docs.tryhelium.com")!)

            case .webviewRenderFail, .bridgingError:
                return ("View Docs", URL(string: "https://docs.tryhelium.com")!)

            case .forceShowFallback, .invalidResolvedConfig, .secondTryNoMatch:
                return ("Fallbacks Guide", URL(string: "https://docs.tryhelium.com/sdk/quickstart-ios#fallback-bundles")!)
            }
        }()

        return DiagnosticContent(bodyText: bodyText, ctaTitle: ctaTitle, ctaURL: ctaURL)
    }

    // MARK: - Factory from PaywallSkippedReason

    static func from(skipReason: PaywallSkippedReason, bodyText: String) -> DiagnosticContent {
        let (ctaTitle, ctaURL): (String, URL) = {
            switch skipReason {
            case .targetingHoldout:
                return ("Learn About Targeting", URL(string: "https://docs.tryhelium.com/sdk/quickstart-ios#experiments")!)
            case .alreadyEntitled:
                return ("Learn About Entitlements", URL(string: "https://docs.tryhelium.com/sdk/quickstart-ios#checking-subscription-status-%26-entitlements")!)
            }
        }()

        return DiagnosticContent(bodyText: bodyText, ctaTitle: ctaTitle, ctaURL: ctaURL)
    }
}

// MARK: - SwiftUI View

struct HeliumPaywallDiagnosticView: View {
    let content: DiagnosticContent
    let triggerName: String
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var doNotShowAgain: Bool = UserDefaults.standard.bool(forKey: "heliumDiagnosticDoNotShowAgain")

    private var triggerTextColor: Color {
        colorScheme == .dark
            ? Color(red: 241/255, green: 233/255, blue: 253/255)
            : Color(red: 44/255, green: 112/255, blue: 106/255)
    }

    private var triggerBackgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 118/255, green: 44/255, blue: 200/255)
            : Color(red: 213/255, green: 248/255, blue: 239/255)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Dismiss button
                HStack {
                    Spacer()
                    Button(action: {
                        if doNotShowAgain {
                            UserDefaults.standard.set(true, forKey: "heliumDiagnosticDoNotShowAgain")
                        }
                        onDismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 8)

                // Logo + Trigger group
                Image("heliumlogo", bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                Button(action: {
                    UIPasteboard.general.string = triggerName
                }) {
                    HStack(spacing: 10) {
                        VStack(spacing: 5) {
                            Text("Trigger")
                                .font(.subheadline)
                                .foregroundColor(triggerTextColor)
                            Text(triggerName)
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundColor(triggerTextColor)
                        }
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(triggerTextColor)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(triggerBackgroundColor)
                    .cornerRadius(12)
                }
                .padding(.top, 30)

                // Body text
                Text(content.bodyText)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 28)

                // CTA button + copy
                HStack(spacing: 12) {
                    Button(action: {
                        UIApplication.shared.open(content.ctaURL)
                    }) {
                        Text(content.ctaTitle)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }

                    Button(action: {
                        UIPasteboard.general.string = content.ctaURL.absoluteString
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.body)
                            .padding(14)
                            .background(Color(.systemGray5))
                            .cornerRadius(12)
                    }
                }
                .padding(.top, 32)

                // Checkbox + Footer
                Toggle(isOn: $doNotShowAgain) {
                    Text("Do not show again on this device")
                        .font(.subheadline)
                }
                .toggleStyle(CheckboxToggleStyle())
                .padding(.top, 25)

                Text("This diagnostic view is only shown in DEBUG builds.\n\nYou can disable it by setting Helium.config.paywallNotShownDiagnosticDisplayEnabled to false.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, 38)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 30)
        }
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

    /// Dismisses the diagnostic view if it is currently presented.
    @MainActor
    static func dismissIfPresented() {
        guard isCurrentlyPresented, let controller = presentedController else { return }
        controller.dismiss(animated: false)
        isCurrentlyPresented = false
        presentedController = nil
    }

    @MainActor
    static func presentIfNeeded(
        trigger: String,
        unavailableReason: PaywallUnavailableReason?,
        message: String
    ) {
        guard shouldPresent() else { return }

        let content = DiagnosticContent.from(
            unavailableReason: unavailableReason,
            bodyText: message
        )
        present(content: content, triggerName: trigger)
    }

    @MainActor
    static func presentIfNeeded(
        trigger: String,
        skipReason: PaywallSkippedReason,
        message: String
    ) {
        guard shouldPresent() else { return }

        let content = DiagnosticContent.from(skipReason: skipReason, bodyText: message)
        present(content: content, triggerName: trigger)
    }

    @MainActor
    private static func shouldPresent() -> Bool {
        guard Helium.config.paywallNotShownDiagnosticDisplayEnabled else { return false }
        guard !UserDefaults.standard.bool(forKey: "heliumDiagnosticDoNotShowAgain") else { return false }
        guard !isCurrentlyPresented else { return false }
        return true
    }

    @MainActor
    private static func present(content: DiagnosticContent, triggerName: String) {
        guard let topVC = UIWindowHelper.findTopMostViewController() else { return }

        isCurrentlyPresented = true

        let diagnosticView = HeliumPaywallDiagnosticView(
            content: content,
            triggerName: triggerName,
            onDismiss: {
                topVC.presentedViewController?.dismiss(animated: true) {
                    isCurrentlyPresented = false
                }
            }
        )

        let hostingController = UIHostingController(rootView: diagnosticView)
        hostingController.modalPresentationStyle = .fullScreen
        presentedController = hostingController

        topVC.present(hostingController, animated: true)
    }
}

#endif
