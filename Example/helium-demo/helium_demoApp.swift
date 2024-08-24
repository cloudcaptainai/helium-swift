//
//  helium_demoApp.swift
//  helium-demo
//
//  Created by Anish Doshi on 8/8/24.
//

import SwiftUI
import Helium
import HeliumCore
import HeliumTemplatesLocket
import StoreKit

class DemoHeliumPaywallDelegate: HeliumPaywallDelegate {
    var subscriptions: [Product]
    
    public init() {
        self.subscriptions = []
        Task {
            do {
                let products = try await Product.products(for: ["yearly_sub_subscription", "monthly_sub_id"])
                self.subscriptions = products
            } catch {
                print("failed to load subscriptions")
            }
        }
    }
    
    func makePurchase(productId: String) async -> HeliumCore.HeliumPaywallTransactionStatus {
        do {
            let result = try await self.subscriptions[1].purchase();
            switch (result) {
                case .success(let result):
                    return .purchased;
                case .userCancelled:
                    return .cancelled;
                case .pending:
                    return .pending
                @unknown default:
                    return .failed(NSError(domain:"", code: 401, userInfo:[ NSLocalizedDescriptionKey: "Unknown error making purchase"]))
            }
        } catch {
            return .failed(error)
        }
    }
}


@main
struct helium_demoApp: App {
    
    init() {
        Task {
            let delegate = DemoHeliumPaywallDelegate()
            
            await Helium.shared.initializeAndFetchVariants(
                apiKey: "sk_1234567890",
                heliumPaywallDelegate: delegate,
                baseTemplateView: LocketBaseTemplateView.self,
                useCache: true
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
