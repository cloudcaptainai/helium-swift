import UIKit
import WebKit

/// Safe-area insets (in points, which paywall bundles treat as CSS px) reported to the paywall
/// web content, both seeded into `heliumContext.screenInfo.safeAreaInsets` and pushed live through
/// `window.heliumUpdateSafeAreaInsets`.
enum PaywallSafeAreaInsets {

    @MainActor
    static func current(for view: UIView?) -> UIEdgeInsets {
        (view?.window ?? UIWindowHelper.findActiveWindow())?.safeAreaInsets ?? .zero
    }

    static func jsonObject(_ insets: UIEdgeInsets) -> [String: Double] {
        [
            "top": Double(insets.top),
            "bottom": Double(insets.bottom),
            "left": Double(insets.left),
            "right": Double(insets.right),
        ]
    }

    static func updateScript(_ insets: UIEdgeInsets) -> String {
        """
        if (window.heliumUpdateSafeAreaInsets) {
            window.heliumUpdateSafeAreaInsets({
                top: \(Double(insets.top)),
                bottom: \(Double(insets.bottom)),
                left: \(Double(insets.left)),
                right: \(Double(insets.right))
            });
        }
        """
    }

    @MainActor
    static func push(to webView: WKWebView) {
        webView.evaluateJavaScript(updateScript(current(for: webView)))
    }
}

/// Re-reports insets when its safe area or layout changes (rotation, window resizes), which
/// SwiftUI doesn't surface through `updateUIView`.
final class PaywallWebView: WKWebView {
    private var lastReportedInsets: UIEdgeInsets?

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        reportSafeAreaIfChanged()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportSafeAreaIfChanged()
    }

    private func reportSafeAreaIfChanged() {
        guard window != nil else { return }
        let insets = PaywallSafeAreaInsets.current(for: self)
        guard insets != lastReportedInsets else { return }
        lastReportedInsets = insets
        evaluateJavaScript(PaywallSafeAreaInsets.updateScript(insets))
    }
}
