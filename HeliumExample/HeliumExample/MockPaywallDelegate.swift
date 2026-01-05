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

    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        // Show visual indicator that UI tests can detect
        await MainActor.run {
            showPurchaseIndicator()
        }
        return .purchased
    }

    @MainActor
    private func showPurchaseIndicator() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return }

        let label = UILabel()
        label.text = "Purchase attempted"
        label.accessibilityIdentifier = "makePurchaseCalled"
        label.frame = CGRect(x: 0, y: 0, width: 200, height: 50)
        label.center = window.center
        label.backgroundColor = .black
        label.textColor = .green
        label.textAlignment = .center
        window.addSubview(label)

        // Remove after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            label.removeFromSuperview()
        }
    }
}
