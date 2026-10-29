import UIKit
import WebKit

/// Safe-area insets (in points, which paywall bundles treat as CSS px) reported to the paywall
/// web content, both seeded into `heliumContext.screenInfo.safeAreaInsets` and pushed live through
/// `window.heliumUpdateSafeAreaInsets`.
enum PaywallSafeAreaInsets {

    @MainActor
    static func current(for view: UIView?) -> UIEdgeInsets {
        guard let window = view?.window ?? UIWindowHelper.findActiveWindow() else {
            return .zero
        }
        guard HeliumFetchedConfigManager.shared.isFeatureEnabled(.viewRelativeSafeArea),
              let view, view.window === window, !view.bounds.isEmpty else {
            return window.safeAreaInsets
        }
        return clipped(
            windowInsets: window.safeAreaInsets,
            windowBounds: window.bounds,
            viewFrame: view.convert(view.bounds, to: window)
        )
    }

    /// Keeps only the part of each window inset that the view actually overlaps, so a paywall that
    /// doesn't reach a screen edge (e.g. embedded below a header) gets 0 on that edge.
    static func clipped(windowInsets: UIEdgeInsets, windowBounds: CGRect, viewFrame: CGRect) -> UIEdgeInsets {
        func overlap(_ inset: CGFloat, _ distanceFromEdge: CGFloat) -> CGFloat {
            min(inset, max(0, inset - distanceFromEdge))
        }
        return UIEdgeInsets(
            top: overlap(windowInsets.top, viewFrame.minY - windowBounds.minY),
            left: overlap(windowInsets.left, viewFrame.minX - windowBounds.minX),
            bottom: overlap(windowInsets.bottom, windowBounds.maxY - viewFrame.maxY),
            right: overlap(windowInsets.right, windowBounds.maxX - viewFrame.maxX)
        )
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
