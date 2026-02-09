//
//  MockPaywallDelegate.swift
//  HeliumExample
//
//  Created for UI testing purposes.
//

import UIKit
import Helium

/// A mock delegate for UI testing that simulates successful purchases
class MockPaywallDelegate: HeliumPaywallDelegate {

    /// Controls restore behavior. Set via launch arguments.
    var shouldRestoreSucceed: Bool = false

    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        // Show visual indicator that UI tests can detect
        await MainActor.run {
            showPurchaseIndicator()
        }
        return .purchased
    }

    func restorePurchases() async -> Bool {
        shouldRestoreSucceed
    }

    @MainActor
    private func showPurchaseIndicator() {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }

        // Create a dedicated window that survives paywall dismissal
        let indicatorWindow = UIWindow(windowScene: windowScene)
        indicatorWindow.windowLevel = .alert + 1
        indicatorWindow.backgroundColor = .clear
        indicatorWindow.isUserInteractionEnabled = false

        let label = UILabel()
        label.text = "Purchase attempted"
        label.accessibilityIdentifier = "makePurchaseCalled"
        label.frame = CGRect(x: 0, y: 0, width: 200, height: 50)
        label.backgroundColor = .black
        label.textColor = .green
        label.textAlignment = .center

        let rootVC = UIViewController()
        rootVC.view.backgroundColor = .clear
        rootVC.view.addSubview(label)
        label.center = rootVC.view.center

        indicatorWindow.rootViewController = rootVC
        indicatorWindow.isHidden = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            indicatorWindow.isHidden = true
        }
    }
}
