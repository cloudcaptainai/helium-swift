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

    private static let defaultURL = URL(string: "https://docs.tryhelium.com/sdk/quickstart-ios")!

    /// Extracts the first URL found in the given text and returns it along with the text stripped of that URL.
    private static func extractAndStripURL(from text: String) -> (url: URL, strippedText: String) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text),
              let url = URL(string: String(text[range])) else {
            return (defaultURL, text)
        }
        let stripped = text.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespaces)
        return (url, stripped)
    }

    static func from(bodyText: String) -> DiagnosticContent {
        let (url, strippedText) = extractAndStripURL(from: bodyText)
        let ctaTitle: String
        if url == defaultURL {
            ctaTitle = "View Docs"
        } else if url.host?.contains("app.tryhelium.com") == true {
            ctaTitle = "Open Dashboard"
        } else {
            ctaTitle = "View Docs"
        }
        return DiagnosticContent(bodyText: strippedText, ctaTitle: ctaTitle, ctaURL: url)
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
                .padding(.top, 40)

                // Body text
                Text(content.bodyText)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 32)

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
                .padding(.top, 40)

                // Checkbox + Footer
                Toggle(isOn: $doNotShowAgain) {
                    Text("Do not show again on this device")
                        .font(.subheadline)
                }
                .toggleStyle(CheckboxToggleStyle())
                .padding(.top, 30)

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
    static func presentIfNeeded(
        trigger: String,
        message: String
    ) {
        guard shouldPresent() else { return }

        let content = DiagnosticContent.from(bodyText: message)
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

#endif
